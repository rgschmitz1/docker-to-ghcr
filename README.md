# Purpose
Backup container images from Docker hub to GitHub Container Registry (GHCR)

# Usage
```bash
usage: docker-to-ghcr.sh <Docker namespace>
                                                                                               
inputs:                                                                                        
  Docker namespace - Source to pull container images
```

# Limitations
GHCR defaults to 'private' container image visibility, there is currently no API mechanism to change visibility.

# Known issues
There is a rate-limit on pulling container images on docker.io, to increase the rate-limit a valid Docker hub login must be entered.
