# Purpose
Backup container images from Docker hub to GitHub Container Registry (GHCR)

# Usage
```bash
usage: docker-to-ghcr.sh <Docker username> <GitHub username> <GitHub API key>                                                                                                                 
                                                                                               
inputs:                                                                                        
  Docker username - Source to generate container image list                                    
  GitHub username - Destination account to push container images                                                                                                                              
  GitHub API key  - Authenticate user to push container images
```

# Limitations
GHCR defaults to 'private' container image visibility, there is currently no API mechanism to change visibility.
