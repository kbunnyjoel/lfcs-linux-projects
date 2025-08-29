# Project 1: Nginx Setup Automation

## Overview
This project automates the deployment and configuration of the Nginx web server tailored for both development and production environments. It simplifies setup by providing modular scripts that handle environment-specific configurations, TLS certificate management, and health monitoring.

## Features
- **Development and Production Modes:** Easily switch between development and production configurations to suit your deployment needs.
- **TLS Automation:** Automatically obtain and configure TLS certificates for secure HTTPS connections.
- **Health Checks:** Integrated health check scripts to monitor the status and performance of the Nginx server.
- **Modular Scripts:** Organized and reusable scripts for environment setup, configuration, and maintenance.

## Usage
- To install and configure Nginx, run the install script with the desired environment mode:
  ```
  ./install.sh dev
  ```
  or
  ```
  ./install.sh prod
  ```
  To view help and usage options:
  ```
  ./install.sh --help
  ```
  Output:
  ```
  Usage: ./install.sh [options] [environment]

  Options:
    --bg       Run Nginx in background mode (development only). Production always runs in background with TLS enabled.
    -h, --help Show this help message and exit.

  Environments:
    dev        Setup Nginx in development mode.
    prod       Setup Nginx in production mode with TLS.
  ```

- To stop the Nginx service (on macOS/Homebrew installations):
  ```
  brew services stop nginx
  ```
- To restart the Nginx service (on macOS/Homebrew installations):
  ```
  brew services restart nginx
  ```
  On Linux systems (or if running outside of macOS/Homebrew), you may use:
  ```
  sudo systemctl stop nginx
  sudo systemctl restart nginx
  ```

## Folder Structure
- **env/**: Contains environment-specific configuration files for development and production.
- **setup/**: Scripts responsible for installing and configuring Nginx and related components.
- **lib/**: Reusable library scripts that provide common functions and utilities used across the setup process.

## Compatibility
This project works natively on macOS using Homebrew paths and `brew services` for managing the Nginx service. It also supports Linux systems with minor adjustments, such as using `apt` or `yum` for installing Nginx and `systemctl` for service management.

## Benefits
This project demonstrates essential Linux administration skills including service management and configuration. It showcases automation through scripting, secure TLS setup, implementation of health checks for reliability, and the use of modular code design for maintainability and scalability.
