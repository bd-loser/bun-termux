# Bun armv7 Migration Workflow

This repository is now the primary owner of Bun armv7 migration attempts.

## Responsibility split

- `bun-termux`: Bun armv7 cross/native build attempts and handoff artifacts
- `opencode-termux`: consumes Bun armv7 output and builds OpenCode armv7 packaging flow

## Workflow

- Workflow file: `.github/workflows/armv7.yml`
- Cross path artifact: `bun-armv7-cross-prebuild`
- Native fallback artifact: `bun-armv7-native-fallback`

## Dispatch options

- `bun_version`: Bun tag to test
- `run_native_armv7`: set `true` only when self-hosted armv7 runner is ready

## Outputs to inspect

- `status/build-attempt-status.json`
- `status/next-build-path.json`
- `status/bun-source-build-status.json`
- `logs/build-bun-armv7.log`
- `logs/build-bun-armv7-source.log`

## Dependency policy

All generated package templates and package metadata keep `glibc-runner` as required dependency.
