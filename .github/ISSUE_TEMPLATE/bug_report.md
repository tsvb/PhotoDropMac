---
name: Bug report
about: Something went wrong during an ingest, verify, sync or heal
labels: bug
---

**What happened**

<!-- What you expected, and what you got instead. -->

**Version**

- App version (PhotoDrop → About):
- `photodrop --version`:
- macOS version:
- Mac model (Apple silicon / Intel):

**The job**

- Source: memory card / folder — filesystem if you know it (exFAT, APFS…)
- Destinations: how many, and what they are (local disk, external SSD, NAS/SMB…)
- Verification on?  Eject after ingest on?

**Evidence**

The job log is at `~/Library/Logs/PhotoDrop/` and the manifest at
`<destination>/PhotoDrop Manifests/`. Paste the relevant lines, or attach the
log. If the completion sheet showed failures, its **Copy Details** button puts
the list on your clipboard.

Please redact anything you would rather not publish — paths can be revealing.
Never attach photos.
