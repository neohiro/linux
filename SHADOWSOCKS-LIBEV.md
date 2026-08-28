# ShadowSocks

```bash
# Update system packages per distro (see README cross-distro matrix).
```
```bash
# shadowsocks-libev package name: apt=shadowsocks-libev, dnf/yum=shadowsocks-libev,
# zypper=shadowsocks-libev, pacman=shadowsocks-libev
sudo pkg_install shadowsocks-libev   # if sourced from a neohiro/linux helper context
```
```bash
sudo nano /etc/shadowsocks-libev/config.json
```
for servers (or fill in same for client data with "local_address":127.0.0.1" uncommented):
```json
{
    "server":["::0", "0.0.0.0"],
    "mode":"tcp_and_udp",
    "server_port":8888,
    #"local_address":127.0.0.1",
    "local_port":1080,
    "password":"PWRD<<<<<<<<<<<<<",
    "timeout":300,
    "method":"xchacha20-ietf-poly1305"
    #"plugin": "obfs-server",
    #"plugin_opts": "obfs=http"
}
```
```bash
sudo systemctl restart shadowsocks-libev.service
```
```bash
systemctl status shadowsocks-libev.service
```
for servers:
```bash
sudo iptables -I INPUT -p tcp --dport 8888 -j ACCEPT
sudo iptables -I INPUT -p udp --dport 8888 -j ACCEPT
```
```bash
sudo pkg_install iptables-persistent 2>/dev/null \
  || sudo pkg_install iptables-services 2>/dev/null || true
```
```bash
sudo netfilter-persistent save
```
https://linuxconfig.org/how-to-make-iptables-rules-persistent-after-reboot-on-linux
```bash
# firewalld (RHEL / Fedora / SUSE / Arch):
sudo firewall-cmd --add-port=8888/tcp --add-port=8888/udp --permanent
sudo firewall-cmd --reload
# or UFW (Debian / Ubuntu):
sudo ufw allow 8888
```
Set up Shadowsocks client and optionally set up obfuscation (remove 2x '#' in json above):
```bash
# simple-obfs: apt=simple-obfs, dnf/yum=simple-obfs, pacman=obfs4proxy (AUR: simple-obfs)
sudo pkg_install simple-obfs
```

Or a docker install via [https://github.com/teddysun/shadowsocks_install/blob/master/docker/shadowsocks-libev/README.md]
