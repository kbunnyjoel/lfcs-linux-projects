# lfcs-linux-projects

Practical Linux projects from beginner to advanced for LFCS preparation.

## Project Overview

This repository contains practical Linux projects ranging from beginner to advanced levels, designed specifically for LFCS preparation.

## Structure

- `project1-nginx-setup/`: Main project folder.
- `env/`: Contains `dev.env` and `prod.env` files for environment-specific variables.
- `setup/`: Contains `install.sh` and a `lib` folder with `common`, `nginx`, `health`, and `tls` scripts.

## How to Run

1. Clone the repository.
2. Change directory into the `setup` folder.
3. Give the script execute permissions using `chmod +x install.sh`.
4. Run the script with the appropriate parameters:
   - For development mode (runs in foreground by default): `./install.sh dev`
   - To run development mode in the background: `./install.sh dev --bg`
   - For production mode (nginx runs in background with SSL setup if enabled): `./install.sh prod`
   - To display help/usage instructions: `./install.sh --help`

### Usage

```
Usage: ./install.sh [dev|prod] [--bg] [--help]

Options:
  dev       Run the setup in development mode (foreground by default)
  prod      Run the setup in production mode (nginx runs in background with SSL)
  --bg      Run development mode in the background
  --help    Display this help message
```

## Features

- Automated package installation.
- Environment-specific configuration automatically selected based on parameters.
- Modular code split into lib files.
- Foreground/background toggle for development mode.
- Built-in help/usage instructions.
- Automatic health checks after deployment.
- SSL setup for production.
- Logging in production.


## Project 1 Benefits

This project demonstrates a real-world, automated, environment-aware deployment process while being flexible enough to run in both development and production modes.

- **LFCS Exam Preparation**: Practices Linux administration tasks such as package installation, process control, service management, configuration changes, permissions, and troubleshooting.
- **Real-World Dev/Prod Workflow**: Runs Nginx in foreground mode for local development or as a background service with optional SSL for production.
- **Fully Automated Setup**: Handles installation, configuration, site deployment, service management, and health checks with one command.
- **Modular & Scalable Code**: Code is split into reusable `lib` scripts, making it easy to extend or maintain.
- **Developer & Sysadmin Friendly**: Includes `--help` for usage guidance, supports background/foreground toggle, and automatically loads environment-specific settings.
