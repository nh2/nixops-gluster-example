#!/usr/bin/env python3

import argparse
import consul
import datetime
import logging
import os
import signal
import socket
import subprocess
import sys
import time

from requests.exceptions import ConnectionError


# Prefer waitForSession instead, see:
#   https://github.com/hashicorp/consul/issues/819#issuecomment-319745456
def waitForLeader(args):
  c = consul.Consul(consistency='consistent')

  while True:
    try:
      leader_output = c.status.leader()
      if leader_output != '':
        logging.debug("got leader: {0}".format(leader_output))
        got_leader = True
        break
      else:
        logging.debug("got empty leader, retrying")
    except ConnectionError as e:
      logging.warning("got connection error when trying to connect to consul, retrying (exception was: {0})".format(e))
    except consul.ConsulException as e:
      logging.warning("got consul error when trying to get leader, retrying (exception was: {0})".format(e))
    time.sleep(0.1)


def waitForSession(args):
  c = consul.Consul(consistency='consistent')

  while True:
    session = None
    try:
      logging.debug("trying to get session")
      session = c.session.create(name="consul-scripting-helper waitForSession", ttl=10)
      logging.debug("got session: " + session)
      c.session.destroy(session)
      session = None
      break
    except ConnectionError as e:
      logging.warning("got connection error when trying to connect to consul, retrying (exception was: {0})".format(e))
    except consul.ConsulException as e:
      logging.warning("got consul error when trying to create session, retrying (exception was: {0})".format(e))
    finally:
      if session is not None:
        # This can only happen when an exception blew us up because otherwise
        # we'd have set `session = None` above.
        logging.error('Exception while holding consul session, destroying session')
        c.session.destroy(session)
        session = None
    time.sleep(0.1)


# Same as https://github.com/hashicorp/consul/blob/v0.8.3/api/lock.go#L38
# to be compatible with the `consul lock` command.
lockFlagValue = 0x2ddccbc058a50c18


def locked_action(key, f, c=None, session_ttl=None):
  lockKey = key + '/.lock'

  c = c or consul.Consul(consistency='consistent')

  pid = os.getpid()

  while True:
    session = None
    try:
      now = datetime.datetime.now()
      session = c.session.create(name="consul-scripting-helper[" + str(pid) + "] locked_action " + key + " (" + str(now) + ")", ttl=session_ttl)

      # Acquire lock
      acquired = False
      index = None
      while not acquired:
        # Look for an existing lock, blocking until not taken
        logging.debug("issuing 'get'")
        # We have to wait less than the session TTL, otherwise our session will time out
        wait_seconds = session_ttl * 0.8 if session_ttl is not None else None
        index, data = c.kv.get(lockKey, index=index, wait=str(wait_seconds) + 's')
        logging.debug("'get' returned: {0}".format((index, data)))
        if session_ttl is not None:
          logging.debug("renewing session: " + session)
          c.session.renew(session)
        if data is not None:
          if data['Flags'] != lockFlagValue:  # same as https://github.com/hashicorp/consul/blob/v0.8.3/api/lock.go#L197
            raise Exception('Existing key does not match lock use (lockKey: {0})'.format(lockKey))
          if 'Session' in data:  # if somebody else has the lock we can't acquire it; same as https://github.com/hashicorp/consul/blob/v0.8.3/api/lock.go#L204
            logging.debug("lock is already held by session '{0}', retrying".format(data['Session']))
            continue

        now = datetime.datetime.now()
        acquired = c.kv.put(lockKey, socket.gethostname() + ' (' + str(now) + ')', acquire=session, flags=lockFlagValue)

      # Now we have the lock.
      logging.debug("got lock")

      # We need to track the index at which we acquired it, so that we can pass
      # that to `delete` below.
      acquired_index, _ = c.kv.get(lockKey)
      logging.debug("lock acquired index is {0}, running command".format(acquired_index))

      try:
        # Perform action.
        res = f(c, session)
        logging.debug("lock command finished")
        return res
      except:
        logging.exception('Exception in locked action')
        raise
      finally:

        # Delete lock key (which will automatically release the lock)

        # We need to call `delete` with `cas=acquired_index`, so that we can
        # only delete if nobody else has acquired it since (otherwise we would
        # be deleting their lock under their feet).
        # We _should_ own the lock, but it may not be so if an operator or health
        # check forcefully took it away from us. In that case don't want
        # the program to continue as an assumption is violated, so we raise.
        # TODO Potentially we want to try-loop around this as well in case consul goes down.
        did_delete = c.kv.delete(lockKey, cas=acquired_index)
        if did_delete:
          logging.debug("deleted lock")
        else:
          raise Exception('lock deletion failed; perhaps an operator or health check took the lock way from us (lockKey: {0})'.format(lockKey))

        c.session.destroy(session)
        session = None
    except ConnectionError as e:
      logging.warning("got connection error when trying to connect to consul, retrying (exception was: {0})".format(e))
    except consul.ConsulException as e:
      logging.warning("got consul error in locked_action, retrying (exception was: {0})".format(e))
      # TODO Potentially don't retry here and above if f() has already finished,
      #      so that it doesn't get run twice
    except:
      raise
    finally:
      if session is not None:
        # This can only happen when an exception blew us up because otherwise
        # we'd have set `session = None` above.
        logging.error('Exception while holding consul session, destroying session')
        c.session.destroy(session)
        session = None
    time.sleep(0.1)


def lockedCommand(args):
  key = args.key
  shell_command = args.shell_command
  pass_check_id = args.pass_check_id

  c = consul.Consul(consistency='consistent')

  def run_command_with_ttl_refresh(c, session):
    p = subprocess.Popen(shell_command, shell=True)
    while p.returncode is None:
      try:
        p.communicate(timeout=1.0)
        logging.info("command finished")
      except subprocess.TimeoutExpired:
        logging.info("command still running, will refresh session wait again")
        c.session.renew(session)
    return p.returncode

  returncode = locked_action(key, c=c, f=run_command_with_ttl_refresh, session_ttl=10)
  if returncode == 0 and pass_check_id is not None:
    now = datetime.datetime.now()
    c.agent.check.ttl_pass(pass_check_id, notes="Command exited with exit code 0 on " + str(now) + ":\n" + shell_command)
  sys.exit(returncode)


def ensureValueEquals(args):
  key = args.key
  expected_value = args.value.encode('utf-8')

  c = consul.Consul(consistency='consistent')

  index, data = c.kv.get(key)
  logging.debug("'get' returned: {0}".format((index, data)))

  value = data['Value'] if data else None

  is_expected = value == expected_value
  sys.exit(0 if is_expected else 1)


def waitUntilValue(args):
  key = args.key
  target_value = args.value.encode('utf-8') if args.value is not None else None

  c = consul.Consul(consistency='consistent')

  index = None
  while True:
    try:
      index, data = c.kv.get(key, index=index)

      logging.debug("'get' returned: {0}".format((index, data)))

      if data is None:
        continue
      elif target_value is None:  # existence of the key suffices
        break

      value = data['Value']
      assert type(value) == type(target_value) == bytes
      if value == target_value:
        break
    except consul.ConsulException as e:
      logging.warning("got consul error in waitUntilValue, retrying (exception was: {0})".format(e))
    except ConnectionError as e:
      logging.warning("got connection error when trying to connect to consul, retrying (exception was: {0})".format(e))
    time.sleep(0.1)


def counterIncrement(args):
  key = args.key

  c = consul.Consul(consistency='consistent')

  index = None
  success = False
  while not success:
    index, data = c.kv.get(key)

    logging.debug("'get' returned: {0}".format((index, data)))

    integer_to_put = 1  # for the case that the key doesn't exist yet
    cas_index = 0  # 0 is special for put(), creating the key only it doesn't exist
    if data is not None:
      cas_index = index
      try:
        integer_to_put = int(data['Value']) + 1
      except ValueError:
        sys.exit("key '{0}' is not an integer".format(key))

    logging.debug("Trying to 'put' value {0}".format(integer_to_put))

    success = c.kv.put(key, str(integer_to_put), cas=cas_index)

    logging.debug("'put' CAS " + ("succeeded" if success else "failed"))


def waitUntilService(args):
  service = args.service
  wait_for_index_change = args.wait_for_index_change
  node = args.node

  c = consul.Consul(consistency='consistent')

  last_max_check_modify_index = 0
  while True:
    try:
      index = None
      while True:
        # See https://github.com/hashicorp/consul/blob/d5b945cc/website/source/api/health.html.md#sample-response-2 for what `nodes` looks like
        index, nodes = c.health.service(service, index=index, passing=True)
        logging.debug("'health.service' returned: {0}".format((index, nodes)))
        if node is not None:
          nodes = [n for n in nodes if n['Node']['Node'] == node]
          logging.debug("filtered nodes to: {0}".format(nodes))
        if wait_for_index_change:
          max_check_modify_index = max([c['ModifyIndex'] for n in nodes for c in n['Checks']] + [0])
          nothing_new = max_check_modify_index <= last_max_check_modify_index
          if last_max_check_modify_index == 0 or nothing_new:
            if last_max_check_modify_index == 0:  # we only want to update this once
              last_max_check_modify_index = max_check_modify_index
            logging.info("waiting for next index update")
            continue
        if len(nodes) > 0:
          logging.info("service is passing, exiting. Nodes were: {0}".format(nodes))
          return
    except ConnectionError as e:
      logging.warning("got connection error when trying to connect to consul, retrying (exception was: {0})".format(e))
    except consul.ConsulException as e:
      logging.warning("got consul error while waiting for service, retrying (exception was: {0})".format(e))
    time.sleep(0.1)


def main():
  parser = argparse.ArgumentParser(description='Set of consul tooling commands for multi-machine scripting orchestration that are not provided by the `consul` executable.')
  parser.add_argument('--verbose', action='store_true', help='more verbose output')

  subparsers = parser.add_subparsers(dest='command', help='which tool to use')
  subparsers.required = True  # see http://stackoverflow.com/questions/18282403/argparse-with-required-subcommands

  parser_waitForLeader = subparsers.add_parser('waitForLeader', help='wait until a leader is available')
  parser_waitForLeader.set_defaults(func=waitForLeader)

  parser_waitForSession = subparsers.add_parser('waitForSession', help='wait until a session could be started')
  parser_waitForSession.set_defaults(func=waitForSession)

  parser_lockedCommand = subparsers.add_parser('lockedCommand', help='run a shell command wrapped in a distributed lock; similar to `consul lock`, but exits with the exit code of the child command')
  parser_lockedCommand.add_argument('--key', type=str, required=True, help='the consul key under which to create the lock')
  parser_lockedCommand.add_argument('--shell-command', type=str, required=True, help='command to run')
  parser_lockedCommand.add_argument('--pass-check-id', type=str, required=False, help='a check to mark as TTL-passed if the exit code is 0')
  parser_lockedCommand.set_defaults(func=lockedCommand)

  parser_ensureValueEquals = subparsers.add_parser('ensureValueEquals', help='check that a key exists and has a given value; signal result via exit code')
  parser_ensureValueEquals.add_argument('--key', type=str, required=True, help='the consul key whose value to check')
  parser_ensureValueEquals.add_argument('--value', type=str, required=True, help='the expected (string) value')
  parser_ensureValueEquals.set_defaults(func=ensureValueEquals)

  parser_waitUntilValue = subparsers.add_parser('waitUntilValue', help='wait until a key exists (and optionally until it has a given value), then exit')
  parser_waitUntilValue.add_argument('--key', type=str, required=True, help='the consul key to monitor')
  parser_waitUntilValue.add_argument('--value', type=str, required=False, help='the (string) value to wait for; if not given, just waits until the value exists')
  parser_waitUntilValue.set_defaults(func=waitUntilValue)

  parser_incrementCounter = subparsers.add_parser('counterIncrement', help='atomically increment an integer-as-string counter')
  parser_incrementCounter.add_argument('--key', type=str, required=True, help='the consul key to monitor')
  parser_incrementCounter.set_defaults(func=counterIncrement)

  parser_waitUntilValue = subparsers.add_parser('waitUntilService', help='wait until a service is passing with at least one node, then exit')
  parser_waitUntilValue.add_argument('--service', type=str, required=True, help='the consul service to monitor')
  parser_waitUntilValue.add_argument('--node', type=str, required=False, help='only consider services available on the given node')
  parser_waitUntilValue.add_argument('--wait-for-index-change', action='store_true', required=False, help='Wait until the ModifyIndex of the service changed at least once. Used mainly to work around https://github.com/hashicorp/consul/issues/3569')
  parser_waitUntilValue.set_defaults(func=waitUntilService)

  args = parser.parse_args()

  if args.verbose:
    logging.getLogger().setLevel(logging.DEBUG)

  # Translate SIGTERM to SystemExit exception so that we can implement cleanup
  # actions such as destroying consul sessions.
  # See https://docs.python.org/3/library/exceptions.html#SystemExit
  signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(143))

  args.func(args)


if __name__ == '__main__':
  try:
    main()
  except KeyboardInterrupt:
    exit(1)
