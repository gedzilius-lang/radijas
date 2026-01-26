Below is a **programmer-grade handover document** describing the current VPS state, what runs where, what owns which ports and directories, and how to safely add a radio station without breaking the Illuminatics pitch platform.

---

# VPS Handover — srv1178155 (72.60.181.89)

**OS:** Ubuntu 22.04 LTS
**Primary role:** Static SPA hosting (Illuminatics Pitch)
**Secondary planned role:** Radio streaming platform (to be added safely)

---

# 1) Network & Port Allocation

### Active listening services

```
:22   → sshd (remote access)
:80   → nginx (HTTP)
:443  → nginx (HTTPS)
```

### Internal/system services (do not touch)

```
127.0.0.53:53     systemd-resolve (DNS resolver)
127.0.0.1:1721    monarx-agent (security agent)
127.0.0.1:65529   monarx-agent
```

### Important rules

* **Ports 80 and 443 are reserved for nginx only**
* Do NOT bind radio streaming services directly to 80/443
* Radio streaming services must use **custom ports** (example: 8000, 9000, 8443)
* Use nginx reverse proxy if web UI is needed

---

# 2) Web Stack Architecture (Pitch Site)

## Serving Layer

### nginx

* Running as: `www-data`
* Controls all inbound web traffic
* Entry points:

  * HTTP → port 80
  * HTTPS → port 443

### Virtual Host

```
/etc/nginx/sites-enabled/av.peoplewelike.club.conf
→ symlink to:
   /etc/nginx/sites-available/av.peoplewelike.club.conf
```

This server block:

* Serves static files
* Root directory:

```
/var/www/av.peoplewelike.club
```

---

# 3) Directory Layout

## Production website (LIVE)

```
/var/www/av.peoplewelike.club
```

Contents:

```
index.html        (compiled SPA entry)
assets/           (user uploaded images + videos)
```

### Ownership

```
www-data:www-data
```

### Purpose

* This directory is **served directly by nginx**
* Only contains **static production files**
* No Node, no build tools here

---

## Build workspace (SOURCE)

```
/opt/avpitch
```

Contains:

* React/Vite source code
* Node dependencies
* Build configuration
* Generated `/dist` output

### Purpose

* Used ONLY for:

  * Editing UI code
  * Running builds
* NOT publicly exposed

---

# 4) Deployment Pipeline

## Update Script

Location:

```
/usr/local/bin/avpitch-update
```

### What it does

1. Stops running Node build processes
2. Runs:

```
npm install
npm run build
```

3. Preserves uploaded media:

```
/var/www/av.peoplewelike.club/assets
```

4. Deletes old build files
5. Copies new production build from:

```
/opt/avpitch/dist
```

→ into:

```
/var/www/av.peoplewelike.club
```

6. Sets permissions:

```
www-data:www-data
```

7. Reloads nginx safely

---

## Deployment logic summary

```
SOURCE CODE:
  /opt/avpitch

BUILD OUTPUT:
  /opt/avpitch/dist

LIVE WEBSITE:
  /var/www/av.peoplewelike.club
```

**Never edit production files manually** — always modify source in `/opt/avpitch` and rebuild.

---

# 5) Runtime Dependencies

### Node environment (build-only)

Installed:

```
Node.js v20.20.0
npm 10.8.2
```

### Important

Node is NOT running as a server.

It is used only for:

* Building the static SPA
* Then exits

No Node ports are open.

---

# 6) Cloudflare Setup (External)

Domain:

```
av.peoplewelike.club
```

Status:

* Cloudflare proxy ON (orange cloud)
* nginx terminates origin connection
* Cloudflare handles edge TLS + CDN

---

# 7) Security Boundaries

### Public-facing attack surface

Only:

```
22 (SSH)
80 (nginx)
443 (nginx)
```

### Internal protected areas

Not exposed:

```
/opt/avpitch
/usr/local/bin
Node build environment
```

---

# 8) How To Add Radio Station Without Conflict

## Recommended architecture

### A) Use subdomain

Example:

```
radio.peoplewelike.club
```

Never attach radio services under:

```
av.peoplewelike.club
```

---

### B) Directory isolation

If web UI needed:

```
/var/www/radio.peoplewelike.club
```

Streaming server configs:

```
/etc/icecast2/
or
/opt/radio-stack/
```

Never reuse:

```
/opt/avpitch
/var/www/av.peoplewelike.club
```

---

### C) Port isolation

Typical radio ports:

```
8000 (Icecast stream)
9000 (admin)
```

These must NOT overlap with:

```
80
443
22
```

---

### D) nginx routing model

nginx remains entry gatekeeper.

Example:

```
radio.peoplewelike.club → nginx → proxy_pass → localhost:8000
```

This preserves:

* SSL via Cloudflare/nginx
* Single public IP
* Clean separation

---

### E) Process ownership separation (recommended)

Create radio user:

```
useradd -r -s /bin/false radio
```

Run streaming services as:

```
radio
```

Pitch website remains:

```
www-data
```

This prevents cross-permission damage.

---

# 9) What NOT to modify

DO NOT:

* Delete `/opt/avpitch`
* Delete `/usr/local/bin/avpitch-update`
* Modify nginx global config for unrelated services
* Bind radio service directly to :80 or :443
* Serve radio UI from `/var/www/av.peoplewelike.club`

---

# 10) Backup-critical paths

Before major changes:

Backup:

```
/etc/nginx/
/opt/avpitch/
/var/www/av.peoplewelike.club/assets/
/usr/local/bin/avpitch-update
```

---

# 11) Operational Summary (Mental Model)

This VPS is now:

### Static Web Platform

* nginx serves SPA
* Node used only for builds
* No runtime application server

### Expansion-ready

* Plenty of unused ports
* Cloudflare in front
* Reverse proxy ready
* Clean directory separation


Just say which one you want.
