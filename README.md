# PushPop

When Aamir pushes, a dancing cat fades in on Arshad's screen with its sound. When Arshad pushes, it fades in on Aamir's screen. It runs quietly in the background on each Windows PC.

No server, no token, no account, nothing to install. It uses the git login already on each PC.

## Setup (about 5 minutes per PC)

1. Put this folder somewhere permanent, such as your Desktop. Windows starts PushPop from here, so if you move the folder later, run the install line again from its new place.
2. Open PowerShell in the folder and run the line for your PC.

On Arshad's PC:

```bash
powershell -ExecutionPolicy Bypass -File install.ps1 -Me arshad
```

On Aamir's PC:

```bash
powershell -ExecutionPolicy Bypass -File install.ps1 -Me aamir
```

You'll see one line per repo, then the cat plays once, saying how many repos it's watching. That popup is your test: if you see the cat and hear it, setup worked.

If a repo shows `FAIL`, you don't have access from that PC, or git hasn't signed in yet. Run the `git ls-remote` line it prints and sign in. PushPop picks the repo up on its own after that.

You only do this once. After that it runs by itself every time you turn on your PC.

To update to a newer version, replace the files in this folder and run the same install line again. Nothing is lost, and it still shows anything you missed.

## The video

| File | What it's for |
|---|---|
| `assets/cat.mp4` | The video that plays, with its own sound |
| `assets/cat-still.png` | The picture shown if the video can't play on a PC |
| `assets/sound.wav` | The sound played with that picture |

To use a different video, or a different one for each person, put the file in `assets/` and change `video` under that person in `config.json`.

Use an MP4 with a flat green background and leave the green in. Windows can't play see-through video, so PushPop removes the green live as it plays, and the sound stays in sync. Videos stop after 60 seconds. If a video won't open, the still picture shows instead, so a popup always appears.

## Everyday use

- **Pause for a client call:** double-click **PushPop pause** on the desktop. Pushes are still noticed and show when you resume. A forgotten pause ends by itself after 2 hours.
- **Add a project:** add one line under `repos` in `config.json` on both PCs. No restart needed.
- **Add a git identity:** if someone's commits don't trigger popups, add their name to `names` in `config.json`, or their email to `emails`. Emails are stored as fingerprints, so the file can be shared without showing anyone's address. To get one, run this in the folder and paste the result into `emails`:

  ```bash
  powershell -Command "Import-Module .\PushPop.psm1; Get-EmailHash 'their@email.com'"
  ```

  A plain email also works, but then anyone who can see the file can read it.
- **Change the size or loudness:** `figureHeight` and `volume` are in `config.json`. `showSeconds` only applies to the still picture, because a video plays for its full length.
- **Remove it:** run `powershell -ExecutionPolicy Bypass -File uninstall.ps1`.

## How it decides

Every 60 seconds it asks GitHub for the latest commit on every branch of every repo, and compares them with what it saved last time. New commits by the other person mean a popup.

| Situation | What happens |
|---|---|
| PC off | Starts by itself about 30 seconds after you log in, then shows what you missed |
| PC asleep | Carries on when it wakes, then shows what you missed |
| PushPop stops for any reason | Windows checks every 5 minutes and starts it again |
| No internet | Retries every minute, then catches up |
| Screen locked, or no mouse or keyboard for 2 minutes | Holds the popup until you're back |
| A full-screen app or presentation is running | Holds the popup until it closes |
| Many pushes while away | One popup: "Aamir pushed 5 commits to G" |

Only commit history is copied (about 100 KB per repo, in the `data` folder here). Your project folders are never touched.

## Known limits

- Git records who wrote a commit, not who pushed it. If you rebase and push the other person's commits, the popup can show on the wrong screen. Merging, which is how you work on G, is fine.
- A normal Zoom or Meet screen share isn't detected. Use the pause switch for client calls.
- The popup appears on the main screen only.
- If Windows animation effects are turned off, the video still plays, but without the small rise as it appears.
- Commits made in GitHub's website may use a different name or email. Add it to `config.json` if so.
- A scheduled task called `PushPop` runs the scripts in this folder at every login. Only take changes from people you trust, as with any repo you run.

## If nothing pops up

Check `data\log.txt` in this folder. Every start, exit, check failure and popup is written there.

## Tests

```bash
powershell -ExecutionPolicy Bypass -File tests/run-all.ps1
```

Add `-Live` to also read the real GitHub repos (read-only). Popups flash in the corner while the tests run. The install tests stop any running watcher, and its task brings it back within 5 minutes.
