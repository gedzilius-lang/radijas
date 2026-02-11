# Incident Log

## 2026-02-05: radio.peoplewelike.club routing to wrong site

**Symptom:** radio.peoplewelike.club serves av.peoplewelike.club or wrong content

**Root cause:** 
1. Nginx not running
2. Missing HTTPS (443) server blocks - only HTTP (80) configured
3. No SSL certificates exist in /etc/letsencrypt/live/

**Diagnostic commands:**
```bash
# Check HTTP routing
curl -sI http://127.0.0.1/ -H 'Host: radio.peoplewelike.club' | head

# Check HTTPS routing  
curl -skI https://127.0.0.1/ -H 'Host: radio.peoplewelike.club' | head

# List all listen directives
nginx -T 2>/dev/null | grep -E "^\s*listen" | sort -u

# Check nginx running
ps aux | grep nginx | grep -v grep
```

**Fix:**
1. Start nginx: `nginx -t && nginx`
2. Add 443 server blocks with SSL certs
3. Run certbot for SSL: `certbot --nginx -d radio.peoplewelike.club -d stream.peoplewelike.club`
