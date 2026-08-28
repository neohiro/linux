```bash
docker pull wizardrysteamworks/corrade:latest
```
```bash
docker run -d --name corrade --restart=unless-stopped -v /corrade/config:/etc/corrade -p 54379:54377 wizardrysteamworks/corrade:latest
```


## Firewall

Open the published port before exposing:

```bash
# firewalld (RHEL / Fedora / SUSE / Arch):
sudo firewall-cmd --add-port=54379/tcp --permanent && sudo firewall-cmd --reload
# or UFW (Debian / Ubuntu):
sudo ufw allow 54379/tcp
```
