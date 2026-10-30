# File sharing with Oir

This isn't real FTP — there's no server and no port. Files ride over SSH, and the
container has a plain directory that both sides see.

```
laptop  ──scp──▶  runner:~/dev  ──bind mount──▶  container:~/dev
laptop  ◀─scp──   runner:~/dev  ◀─bind mount──   container:~/dev
```

The runner's `~/dev` is mounted at `/home/jetbrain/dev` in the container, so
anything written on either side is immediately visible on the other. No sync
daemon, no extra service, nothing to start.

## From the laptop

```sh
./connect.sh push notes.txt          # -> container ~/dev/notes.txt
./connect.sh push ./some-dir         # -> container ~/dev/some-dir/
./connect.sh pull data.csv           # container ~/dev/data.csv -> ./data.csv
```

`push` and `pull` find the active runner automatically. If more than one is
running you get the arrow-key picker. If none is running they fail with a
pointer to `./connect.sh`.

## From inside the container

You're already in `~/dev` when your shell opens. Just read and write files
there:

```sh
echo hello > ~/dev/from-container.txt     # laptop pulls it with: ./connect.sh pull from-container.txt
ls ~/dev                                  # anything pushed by the laptop
```

The container also knows which laptop it belongs to:

```sh
cat ~/LAPTOP          # laptop hostname + user + how to move files
echo $LAPTOP_HOST     # e.g. fridge.tailXXXX.ts.net
echo $LAPTOP_USER
```

`LAPTOP_HOST` is read from `tailscale status --peers=false --json` on the machine
that ran `./connect.sh`, so having many devices on the tailnet doesn't matter —
it's always *this* laptop.

## Notes for agents

- Shared directory: `/home/jetbrain/dev` (same as `~/dev`).
- Put files meant for the human in `~/dev`; do not assume any other path is
  visible outside the container.
- There is no outbound connection to the laptop from inside the container. The
  laptop pulls. If you need to hand something back, write it to `~/dev` and say
  `./connect.sh pull <name>`.
- `~/dev` lives on the runner VM. When the run ends (6h max, or stopped), it's
  gone. Anything worth keeping must be pulled to the laptop first.

## Requirements and gotchas

- The runner's `~/dev` is created by the workflow's prebuild step, so it exists
  before you connect.
- A container created before this mount existed will warn on attach; run
  `container/doc.sh --reset` (or `--rebuild`) to recreate it with the mount.
- Both commands use the same SSH key as the normal connection
  (`~/.ssh/<repo-name>` or your agent), so if `./connect.sh` works, these do too.
