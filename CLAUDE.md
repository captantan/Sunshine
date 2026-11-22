# captantan fork of Sunshine

Read [CAPTANTAN.md](CAPTANTAN.md) before changing anything here. It lists every change this fork makes, why, and
the files it touches, and it is the step-by-step brief for merging a new stable upstream release.

- Work on branch `captantan` (the default branch). Merge only stable upstream tags, never pre-releases.
- Upstream's GitHub workflows stay removed; `./captantan/check-fork.sh` must say "All good." before every push.
- Do not open PRs, issues or comments on upstream repositories (`SunshineStream/Sunshine`, `LizardByte/*`,
  `VirtualDrivers/*`) without asking the owner.
- Never commit secrets.
- Claude cannot reach the Windows tower; the owner does every step there ([captantan/TOWER-SETUP.md](captantan/TOWER-SETUP.md)).
- The owner watches token use: read big files by line range, and grep CI logs instead of reading them whole.
