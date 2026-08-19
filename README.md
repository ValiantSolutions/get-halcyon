# Halcyon AI Security — Installer

<!--
  Synced automatically from the Halcyon private repository — do not edit this
  copy in get-halcyon; changes here are overwritten on the next release.
  v0.1.0-rc.11 placeholders are replaced with the release tag at sync time.
-->

This repository contains `halcyon.sh`, the bootstrap installer for
[Halcyon AI Security](https://valiantsolutions.com) — Valiant Solutions'
federal cybersecurity compliance platform.

**The script is public; the product is not.** Everything `halcyon.sh` downloads
(container images, release assets) requires a customer deploy token issued by
Valiant Solutions. Without a token from your Valiant Solutions Sales Engineer,
the installer cannot fetch anything.

**The only official source for this installer is
`github.com/ValiantSolutions/get-halcyon`.** Valiant SEs always link this repo
directly — treat a copy on any other host, or under any other spelling, as
suspect.

Current release: `v0.1.0-rc.11`

---

## Before You Start

- Have your customer deploy token ready (issued by your Valiant Solutions SE)
- Have your customer `.env` configuration file (provided during onboarding)
- **Inspect the script before running it.** Download it, read it, then execute
  it — never pipe curl to bash.

---

## Docker Install

```bash
mkdir halcyon && cd halcyon

# Download and inspect the installer
curl -fLO https://raw.githubusercontent.com/ValiantSolutions/get-halcyon/v0.1.0-rc.11/halcyon.sh
less halcyon.sh

# Recommended: verify the checksum against the value in your onboarding
# packet or the v0.1.0-rc.11 release notes
sha256sum halcyon.sh

chmod +x halcyon.sh

# Enter your customer deploy token (input is hidden, stays out of shell history)
read -rsp 'Deploy token: ' GITHUB_TOKEN; echo; export GITHUB_TOKEN

# Install
./halcyon.sh install-docker --tag v0.1.0-rc.11

# Place your customer .env in this directory (or edit the generated one), then:
./halcyon.sh start

# Done — clear the token from the environment (the GITHUB_TOKEN name is
# honored ambiently by gh and other tooling)
unset GITHUB_TOKEN
```

## EC2 Install

```bash
# Download and inspect the installer
curl -fLO https://raw.githubusercontent.com/ValiantSolutions/get-halcyon/v0.1.0-rc.11/halcyon.sh
less halcyon.sh

# Recommended: verify the checksum against the value in your onboarding
# packet or the v0.1.0-rc.11 release notes
sha256sum halcyon.sh

chmod +x halcyon.sh

# Enter your customer deploy token (input is hidden, stays out of shell history)
read -rsp 'Deploy token: ' GITHUB_TOKEN; echo; export GITHUB_TOKEN

# Place your customer .env in the current directory, then install
sudo -E ./halcyon.sh install-ec2 --tag v0.1.0-rc.11

# Done — clear the token from the environment
unset GITHUB_TOKEN
```

## Upgrades

```bash
# Docker
./halcyon.sh upgrade-docker --tag v0.1.0-rc.11

# EC2
sudo -E ./halcyon.sh upgrade-ec2 --tag v0.1.0-rc.11

# Done — clear the token from the environment
unset GITHUB_TOKEN
```

---

## Getting Help

Issues are disabled on this repository. For installation help, deploy tokens,
or anything else, contact your Valiant Solutions Sales Engineer or your
onboarding contact. To report a security vulnerability, see
[SECURITY.md](SECURITY.md).

---

© Valiant Solutions — provided solely for installing Halcyon; no other rights granted.
