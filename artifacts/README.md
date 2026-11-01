# artifacts/

> **LAB ONLY — fictional local hardening demonstration; do not use with client data or production systems.**

`scripts/lab.ps1` writes each command's sanitized stdout to `artifacts/evidence/<command>.log`. For
example, `test.log` holds the acceptance results and `rollback.log` the rollback evidence.

- **Disposable and Git-ignored:** everything here except this README is ignored by `.gitignore`.
  `V-HYG-01` fails if anything other than this README and `evidence/*.log` appears here.
- **Sanitized:** the logs contain `PASS`, `FAIL` and summary lines, short hash prefixes of the synthetic
  fixture, and counts. They never contain session IDs, cookie values, private keys, certificates, full
  header dumps or environment variables.
- **Not stored here:** fixture data and backup archives live only in the Docker named volumes
  `legacy_state` and `lab_backups`. The TLS key lives only on the edge container's tmpfs.

You can delete `artifacts/evidence/` at any time. The next `lab.ps1` command recreates it.
