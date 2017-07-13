## Certificate creation

### Create root CA cert

```
touch example-root-ca-privkey.pem
chmod 600 example-root-ca-privkey.pem
openssl req -newkey rsa:4096 -days 3650 -x509 -subj "/C=CH/ST=Switzerland/L=Zurich/O=example/OU=Internal/CN=example-ca/emailAddress=support@example.com" -out example-root-ca-cert.pem -keyout example-root-ca-privkey.pem -nodes
```

### Create intitial CA configuration

Ensure `example-ca.conf` exists; then

```
touch certindex
echo 000a > serial
```


### Create CSR for Gluster

```
touch example-gluster-server-privkey.pem
chmod 600 example-gluster-server-privkey.pem
bash -c 'openssl req -newkey rsa:2048 -subj "/C=CH/ST=Switzerland/L=Zurich/O=example/OU=Internal/CN=example-gluster-server/emailAddress=support@example.com" -out example-gluster.csr -keyout example-gluster-server-privkey.pem -nodes'
bash -c 'openssl req -newkey rsa:2048 -subj "/C=CH/ST=Switzerland/L=Zurich/O=example/OU=Internal/CN=example-gluster-client/emailAddress=support@example.com" -out example-gluster.csr -keyout example-gluster-server-privkey.pem -nodes'
```


### Sign CSR to create certificate for Gluster

```
openssl ca -batch -config example-ca.conf -notext -in example-gluster.csr -out example-gluster-server-cert.pem
openssl ca -batch -config example-ca.conf -notext -in example-gluster.csr -out example-gluster-client-cert.pem
```
