# Project 4: Backup Orchestrator

## Overview

Backup Orchestrator is a comprehensive backup management tool designed to handle full, incremental, and differential backups efficiently. It supports restoring from backup artifacts or IDs, manages backup rotation policies, and enables scheduling via cron jobs. The project generates JSON summaries, manifests, and audit logs to maintain transparency and traceability throughout the backup lifecycle. Configuration is environment-specific, supporting separate setups for development and production environments.

## Features

- Full, incremental, and differential backups  
- Restore backups using artifact files or backup IDs  
- Rotation policies to keep the last N full or incremental backups and enforce max-age retention  
- Scheduling of backup tasks through cron integration  
- Generation of JSON summaries, manifests, and detailed audit logs  
- Environment-specific configurations stored in `env/dev` and `env/prod`  

## Folder Structure

```
src/
  └── lib/
tests/
env/
logs/
outputs/
```

- `src/`: Main source code for the backup orchestrator  
- `src/lib/`: Supporting libraries and modules  
- `tests/`: Automated test suites  
- `env/`: Environment configuration files (`dev`, `prod`)  
- `logs/`: Backup and audit log files  
- `outputs/`: Backup artifacts and related output files  

## Usage

Run the following commands to interact with the Backup Orchestrator:

```bash
# Perform a full backup
./backup.sh full

# Perform an incremental backup
./backup.sh inc

# Perform a differential backup
./backup.sh diff

# Restore from a backup artifact or ID
./backup.sh restore <artifact|id>

# Rotate backups according to retention policies
./backup.sh rotate

# Schedule backups using cron
./backup.sh schedule
```

## Testing

To run the automated tests:

```bash
make test
```

Tests are written using the Bats testing framework.

## Development Notes

- Version tags are used to track releases and milestones.  
- Continuous Integration (CI) pipelines are configured to run tests and validate builds on each commit.  
- Developers should follow the branching and tagging conventions outlined in the contributing guidelines.
