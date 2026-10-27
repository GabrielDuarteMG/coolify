# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- Add the preview channel to the CDN, which takes the betas and release candidates

### Changed

- Replace the release process
    - Select the stage and the version with `scripts/release.sh`, which offers the versions the branch allows and preselects the bump the commits need
    - Decide the version, the releases and the moving tags with `scripts/version.sh`, which also reports what a push publishes
    - Sync the CDN with `scripts/sync-cdn.sh` instead of `php artisan sync:cdn`, the stable channel opens a pull request, the preview channel pushes to `main`
- Sync the preview channel of the CDN with the install and upgrade scripts and compose files of the commit it releases, pointed at its channel

### Removed

- Remove the git-cliff workflow that generated `CHANGELOG.md`, it is written by hand
