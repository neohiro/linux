Ideally, use a Docker image pull

```bash
docker pull adguard/dnsproxy
```

Before you can use the dnsproxy server, disable anything running on port 53
```bash
sudo nano /etc/systemd/resolved.conf
```
Change settings to:
```bash
[Resolve]
DNS=1.1.1.3
#FallbackDNS=
#Domains=
#LLMNR=no
#MulticastDNS=no
#DNSSEC=no
#DNSOverTLS=no
#Cache=no
DNSStubListener=no
#ReadEtcHosts=yes
```

Create symlink to new file
```bash
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
```

Change Tor DNS port as well
```bash
sudo nano /etc/tor/torrc
```

Remove previous docker containers before continuing
```bash
docker rm -f $(docker ps -aq)
```

Run the container with the default configuration (see config.yaml.dist) and expose DNS ports
```bash
docker run --name dnsproxy \
  -p 53:53/tcp -p 53:53/udp \
  adguard/dnsproxy
```
Or with a config of your own
```bash
docker run --name dnsproxy \
  -p 53:53/tcp -p 53:53/udp \
  -v config.yaml:/opt/dnsproxy/config.yaml \
  adguard/dnsproxy
```
Accessibility from outside
```bash
# RHEL / Fedora / SUSE / Arch (firewalld):
sudo firewall-cmd --add-port=53/tcp --add-port=53/udp --add-port=443/tcp --permanent
sudo firewall-cmd --reload
# Debian / Ubuntu (UFW):
sudo ufw allow 53 && sudo ufw allow 443
```

If something goes wrong, bypass DNS by using:
```bash
sudo rm /etc/resolv.conf
```
```bash
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf
```
