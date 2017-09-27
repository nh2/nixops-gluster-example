#!/usr/bin/env python3

import argparse
import consul
import logging
import signal
import socket
import subprocess
import sys
import time

from requests.exceptions import ConnectionError


# Prefer waitForSession instead, see:
#   https://github.com/hashicorp/consul/issues/819#issuecomment-319745456
def waitForLeader(args):
  c = consul.Consul()

  while True:
    try:
      leader_output = c.status.leader()
      if leader_output != '':
        logging.debug("got leader: {0}".format(leader_output))
        got_leader = True
        break
      else:
        logging.debug("got empty leader, retrying")
    except ConnectionError:
      logging.info("got connection error when trying to connect to consul, retrying")
    except consul.ConsulException:
      logging.info("got consul error when trying to get leader, retrying")
    time.sleep(0.1)


def waitForSession(args):
  c = consul.Consul()

  while True:
    try:
      logging.debug("trying to get session")
      session = c.session.create(name="consul-scripting-helper waitForSession")
      logging.debug("got session")
      c.session.destroy(session)
      break
    except ConnectionError:
      logging.info("got connection error when trying to connect to consul, retrying")
    except consul.base.ConsulException:
      logging.info("got consul error when trying to create session, retrying")
    time.sleep(0.1)


# Same as https://github.com/hashicorp/consul/blob/v0.8.3/api/lock.go#L38
# to be compatible with the `consul lock` command.
lockFlagValue = 0x2ddccbc058a50c18


def locked_action(key, f):
  lockKey = key + '/.lock'

  c = consul.Consul()

  session = None
  try:
    session = c.session.create(name="consul-scripting-helper locked_action " + key)

    # Acquire lock
    acquired = False
    index = None
    while not acquired:
      # Look for an existing lock, blocking until not taken
      index, data = c.kv.get(lockKey, consistency='consistent', index=index)
      logging.debug("'get' returned: {0}".format((index, data)))
      if data is not None:
        if data['Flags'] != lockFlagValue:  # same as https://github.com/hashicorp/consul/blob/v0.8.3/api/lock.go#L197
          raise Exception('Existing key does not match lock use (lockKey: {0})'.format(lockKey))
        if 'Session' in data:  # if somebody else has the lock we can't acquire it; same as https://github.com/hashicorp/consul/blob/v0.8.3/api/lock.go#L204
          logging.debug("lock is already held by session '{0}', retrying".format(data['Session']))
          continue

      acquired = c.kv.put(lockKey, socket.gethostname(), acquire=session, flags=lockFlagValue)

    # Now we have the lock.

    # We need to track the index at which we acquired it, so that we can pass
    # that to `delete` below.
    acquired_index, _ = c.kv.get(lockKey, consistency='consistent')

    try:
      # Perform action.
      return f()
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
      did_delete = c.kv.delete(lockKey, cas=acquired_index)
      if did_delete:
        logging.debug("deleted lock")
      else:
        raise Exception('lock deletion failed; perhaps an operator or health check took the lock way from us (lockKey: {0})'.format(lockKey))

      c.session.destroy(session)
  except:
    if session is not None:
      logging.error('Exception while holding consul session, destroying session')
      c.session.destroy(session)
    raise


def lockedCommand(args):
  key = args.key
  shell_command = args.shell_command

  returncode = locked_action(key, f=lambda: subprocess.run(shell_command, shell=True).returncode)
  sys.exit(returncode)


def ensureValueEquals(args):
  key = args.key
  expected_value = args.value.encode('utf-8')

  c = consul.Consul()

  index, data = c.kv.get(key, consistency='consistent')
  logging.debug("'get' returned: {0}".format((index, data)))

  value = data['Value'] if data else None

  is_expected = value == expected_value
  sys.exit(0 if is_expected else 1)


def waitUntilValue(args):
  key = args.key
  target_value = args.value.encode('utf-8')

  c = consul.Consul()

  index = None
  while True:
    index, data = c.kv.get(key, consistency='consistent', index=index)

    logging.debug("'get' returned: {0}".format((index, data)))

    if data is None:
      continue

    value = data['Value']
    assert type(value) == type(target_value) == bytes
    if value == target_value:
      break


def counterIncrement(args):
  key = args.key

  c = consul.Consul()

  index = None
  success = False
  while not success:
    index, data = c.kv.get(key, consistency='consistent')

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
  parser_lockedCommand.set_defaults(func=lockedCommand)

  parser_ensureValueEquals = subparsers.add_parser('ensureValueEquals', help='check that a key exists and has a given value; signal result via exit code')
  parser_ensureValueEquals.add_argument('--key', type=str, required=True, help='the consul key whose value to check')
  parser_ensureValueEquals.add_argument('--value', type=str, required=True, help='the expected (string) value')
  parser_ensureValueEquals.set_defaults(func=ensureValueEquals)

  parser_waitUntilValue = subparsers.add_parser('waitUntilValue', help='wait until a key exists and has a given value, then exit')
  parser_waitUntilValue.add_argument('--key', type=str, required=True, help='the consul key to monitor')
  parser_waitUntilValue.add_argument('--value', type=str, required=True, help='the (string) value to wait for')
  parser_waitUntilValue.set_defaults(func=waitUntilValue)

  parser_incrementCounter = subparsers.add_parser('counterIncrement', help='atomically increment an integer-as-string counter')
  parser_incrementCounter.add_argument('--key', type=str, required=True, help='the consul key to monitor')
  parser_incrementCounter.set_defaults(func=counterIncrement)

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
