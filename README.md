# glowing-invention

The script require root or sudo privileges to run.

The script attempts to detect your Linux distribution and version and configure your package management system for you. In addition, the script do not allow you to customize any installation parameters.

The script install all dependencies and recommendations of the package manager without asking for confirmation. This may install a large number of packages, depending on the current configuration of your host machine.

The script does not provide options to specify which version of Docker to install, and installs the latest version that is released in the “stable” channel.

Do not use the script if Docker has already been installed on the host machine using another mechanism.
