# skills

Gerard's shareable agent skills. Each top-level directory is one self-contained
skill (a `SKILL.md` plus any scripts, tests, and references it needs). They are
tool-neutral: written for any agent that loads skills, not just one client.

```
skills/
  ios-simulator-lock/   coordinate the iOS Simulator across agents sharing one machine
  README.md
```

## Installing a skill on this machine

Skills are discovered from a shared, tool-neutral directory: `~/.agents/skills`.
Point your client at it — Claude Code, for instance, works when each entry in
`~/.claude/skills` is a symlink into `~/.agents/skills`, which makes a skill
placed there visible to Claude Code and to any other agent reading the shared
directory. Check what your client already does:

```sh
ls -la ~/.claude/skills | head    # entries are symlinks into ../../.agents/skills
```

To install a skill from this repo, symlink it into `~/.agents/skills/<name>`:

```sh
ln -s "$PWD/ios-simulator-lock" ~/.agents/skills/ios-simulator-lock
```

Use the skill's own directory name as `<name>`. Remove the symlink to uninstall;
the repo copy stays put.

## Developing

Each skill is a plain directory — edit in place and re-run its tests. For
`ios-simulator-lock`:

```sh
bash ios-simulator-lock/test/simlock-test.sh   # no simulator, no network needed
```
