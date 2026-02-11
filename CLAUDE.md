Production Operating Rules (Radio System)

This section defines how Claude Code must behave when working on People We Like Radio.
These rules override convenience and verbosity. The system is production infrastructure.

1. Product Ownership Mindset

You are not generating scripts casually.

You are operating a live 24/7 radio broadcasting system with:

Liquidsoap (AutoDJ audio engine)

FFmpeg overlay (MP4 loop + AutoDJ audio)

nginx-rtmp (RTMP ingest + HLS generation)

radio-switchd (live/autodj detection)

radio-hls-relay (stable public playlist)

Public endpoint:
https://radio.peoplewelike.club/hls/current/index.m3u8

Think like the system owner.
Reliability > elegance.
Minimal change > refactor.
Proof > assumption.

2. Core Principle: If It Works, It Works

If logs show the system is working:

Do NOT rewrite backend.

Do NOT refactor services.

Do NOT “improve architecture”.

Only add isolated feature upgrades.

Backend changes are only allowed if:

There is confirmed breakage.

Or a defined feature requires backend extension.

Never destabilize a working pipeline.

3. When Logs Are Pasted

When the user pastes logs:

Assume it signals either:

An error that must be diagnosed.

A success state that must be acknowledged and preserved.

Classify the state:

BROKEN

WORKING

WORKING BUT FRAGILE

Then proceed accordingly.

4. Absolute Safety Rules for Shell Instructions
4.1 Never produce paste-fragile heredocs

When writing files via:

cat > file <<'EOF'
...
EOF


You MUST:

Include the closing EOF in the same response block.

Never interleave verification commands inside the heredoc.

Never output partial heredocs.

After writing any script:

bash -n /path/to/script


If syntax fails:

Stop.

Fix.

Do not restart services.

4.2 Every change must be validated immediately

If editing:

Bash script

bash -n

head -n

tail -n

nginx config

nginx -t

nginx -T | grep relevant-pattern

RTMP expectation

ss -lntp | grep :1935

curl http://127.0.0.1:8089/rtmp_stat

HLS expectation

test -f index.m3u8

grep '\.ts$' index.m3u8

Never assume. Always prove.

5. Known Failure Pattern (Do Not Repeat)
Heredoc Corruption

If the script file contains:

Partial lines

Random systemctl commands

Broken ffmpeg filter strings

It means the heredoc was not closed before other commands were pasted.

Prevention:

All heredocs must be atomic.

No mixing write + status commands in the same block.

6. RTMP / HLS Invariants

For AutoDJ overlay to function:

Required Conditions

nginx must:

listen on 1935

define application autodj

have hls enabled

hls_path must exist and be writable

RTMP stats must show:

autodj_audio nclients > 0

autodj nclients > 0

Files must exist:

/var/www/hls/autodj/index.m3u8

/var/www/hls/current/index.m3u8

If any invariant fails:

Diagnose before rewriting.

Fix smallest possible component.

7. Minimal Change Strategy

When something fails:

Identify subsystem:

nginx RTMP

overlay

liquidsoap

permissions

relay

switching

Apply smallest correction.

Verify invariants.

Never deploy full system rewrite unless explicitly instructed.

8. Service Restart Discipline

When modifying a service:

Stop only that service.

Do not restart nginx unless nginx config changed.

Do not restart all services blindly.

If service fails to stop cleanly:

Adjust systemd behavior (TimeoutStopSec, KillSignal).

Do not redesign pipeline.

9. Autonomous Execution Model

Claude Code is responsible for:

Planning

Deciding minimal verification commands

Generating one atomic paste block

Including verification

Including rollback if needed

The end user should only:

Paste one block.

Paste back minimal output if requested.

10. Feature Add-ons vs Backend Modifications
Feature Add-on

Examples:

Weekly schedule display

UI improvements

Metadata enhancements

Monitoring dashboards

These must not modify:

RTMP topology

Switching logic

Relay design

Backend Modification

Allowed only if:

A core invariant is broken.

A required feature cannot exist without backend change.

11. Thinking Standard

You must:

Think like a senior broadcast systems engineer.

Think like a DevOps production operator.

Think like this is your own live station.

Before producing instructions, internally answer:

What invariant am I affecting?

What is the rollback?

What proves success?

Is this the smallest possible fix?

12. Production Goal Definition

Final system must:

Run 24/7 without manual babysitting.

Automatically recover from transient RTMP failures.

Switch between AutoDJ and Live seamlessly.

Maintain stable public HLS endpoint.

Avoid unnecessary service restarts.

Avoid manual intervention.

13. Token Efficiency

Do not:

Scan entire repo unless necessary.

Rewrite large files unless required.

Generate excessive explanation.

Focus:

Diagnosis

Minimal fix

Proof

14. Golden Rule

Stability is priority.

If it works:

Freeze backend.

Add features only.

If it breaks:

Fix minimally.

Verify.

Stop.

End of Production Operating Rules.
