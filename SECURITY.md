# Security policy

## Reporting a vulnerability

Please do not open a public issue for a vulnerability that could expose vault data,
credentials, or filesystem access.

Use GitHub's private vulnerability reporting for this repository. Include:

- the affected version or commit;
- reproduction steps;
- expected and observed behavior;
- the potential impact;
- any suggested mitigation.

You should receive an acknowledgement within seven days. Please allow time for a fix
and coordinated disclosure before publishing details.

## Scope

Security-sensitive areas include:

- sandbox and security-scoped bookmark handling;
- vault path containment and symlink behavior;
- atomic writes, conflict recovery, and deletion;
- extension capability boundaries;
- Keychain-backed extension credentials;
- Markdown parsing or rendering that could trigger unintended file or network access.

The project does not provide a hosted sync service. Security issues in third-party
sync tools, external extension services, or the user's vault content are outside this
repository unless tg-sidian handles them unsafely.
