# MarkLogic bootstrap scripts

Performs initial setup of a MarkLogic host. Assumes MarkLogic has been installed and started.

Initialises host and then either
- configures security - for standalone host or first (bootstrap) host of cluster; or
- joins existing cluster at $CLUSTER_BOOTSTRAP_HOST

## Usage

`./ml-config.sh`

#### Requried environment variables
HOST  
LICENSE_KEY  
LICENSEE  
ADMIN_USER  
ADMIN_PASS  

#### Optional environment variables
CLUSTER_BOOTSTRAP_HOST

When set, the host will join an existing cluster instead of configuring security.
