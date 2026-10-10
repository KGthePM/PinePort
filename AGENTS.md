# Agent Instructions

## Semantic Versioning

This project follows Semantic Versioning using `MAJOR.MINOR.PATCH`.

The authoritative project version is the value in the root `VERSION` file. Any required version references in project metadata or source code must remain consistent with it.

### PATCH

Increment PATCH for fixes and changes that do not add significant new functionality or intentionally break compatibility.

Examples include:

- Bug fixes
- Small UI fixes
- Refactoring without changed external behavior
- Minor configuration corrections
- Performance improvements
- Documentation corrections

Example: `0.5.0` -> `0.5.1`.

### MINOR

Increment MINOR when compatible new functionality or a meaningful project milestone is introduced. While the project is in `0.x`, also increment MINOR for intentional breaking changes.

Examples include:

- New features
- New commands or options
- New UI functionality
- Meaningful enhancements to existing features
- New configuration capabilities
- Intentional breaking changes before `1.0.0`

Example: `0.5.1` -> `0.6.0`.

Reset PATCH to `0` whenever MINOR is incremented.

### MAJOR

Version `1.0.0` marks the first stable release. After `1.0.0`, increment MAJOR for intentional breaking changes.

Examples include:

- Breaking API changes
- Removing established functionality
- Incompatible configuration changes
- Changes requiring users or dependent software to adapt

Example after `1.0.0`: `1.4.2` -> `2.0.0`.

Reset MINOR and PATCH to `0` whenever MAJOR is incremented.

### Pre-1.0 Status

Version `0.5.0` establishes PinePort's versioning baseline. The project remains pre-1.0 while platform support, installation, and behavior are validated, including KDE Plasma testing.

- Bug fixes increment PATCH.
- Compatible new features and meaningful milestones increment MINOR.
- Intentional breaking changes increment MINOR while MAJOR is `0`.
- Move to `1.0.0` only as a deliberate declaration of stable behavior.

### Required Check Before Every Push

Before every push, the agent must:

1. Read the current authoritative version from `VERSION`.
2. Review all changes included in the push, including changes already present in the branch or working tree.
3. Determine the highest SemVer increment justified by those changes.
4. Update `VERSION` before pushing.
5. Update and verify all required references to the project version so they remain consistent with `VERSION`.
6. Never reuse or decrease a version number.
7. Never arbitrarily bump the version beyond what the changes justify.

If multiple types of changes are included, use the highest applicable increment.

Examples:

- Several bug fixes require a PATCH increment.
- Bug fixes plus a new feature require a MINOR increment.
- Before `1.0.0`, an intentional breaking change requires a MINOR increment.
- After `1.0.0`, an intentional breaking change requires a MAJOR increment.
