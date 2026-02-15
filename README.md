# cibuild
----------

A workflow CLI tool for building, testing, and publishing container images using various CI/CD Plattforms. It is included as part of the cibuilder image (see: https://gitlab.com/stack4ops/public/images/generic/cibuilder).

# Purpose
----------

The purpose of cibuild is to streamline and standardize the lifecycle of container images within a GitLab CI pipeline.

# Usage
----------

There are several use cases that are closely tied to the pipeline trigger events defined in the .gitlab-ci.yaml.

```
workflow:
  rules:
    # Trigger rules:
    # The default CI_PIPELINE_SOURCE trigger is schedule
    # Edit or comment in other trigger below

    # Create a pipline on schedules
    - if: $CI_PIPELINE_SOURCE == "schedule"

    # Create a pipline on every push commit
    # - if: $CI_PIPELINE_SOURCE == "push"

    # Create a pipeline on merge_requests_event
    # - if: $CI_PIPELINE_SOURCE == "merge_request_event"

    # Create a pipline on web "Run pipline"
    # - if: $CI_PIPELINE_SOURCE == "web" 

    # Example: Create pipeline on every push on every branch except main branch
    # - if: $CI_COMMIT_BRANCH == "main" && $CI_PIPELINE_SOURCE == "push"
    #   when: never

```

### Schedule trigger

One of the primary use cases is the scheduled rebuilding and retagging of a custom image whenever a newer base image becomes available for a major tag such as latest.

The built-in check stage parses the FROM line of the Dockerfile. If a new base image is detected, the check stage retrieves the unique sha256 digest behind the updated major tag and triggers the build pipeline. When a regular expression is defined in the minor_tag_regex variable of cibuild.cfg, the system also looks for a corresponding minor tag. If found, this minor tag is stored as a cache entry and used as an additional image tag during the release stage.

As a result, your images automatically inherit a tagging scheme that mirrors that of the upstream base images. When the cursor (i.e., the moving pointer of the upstream tag) advances, the cursor of your own image advances as well.

This approach differs slightly from dependency checkers like renovatebot: https://docs.renovatebot.com/docker/

Both methods are valid and come with their own advantages and trade-offs. If you’d rather rely on a renovatebot check, just enable and configure a Merge-Request or Pull-Request trigger, and let Renovate handle triggering the pipeline.

The flow of embedded check:

```
             ┌──────────────────────────┐
             │        check stage       │
             └─────────────┬────────────┘
                           │
                           ▼
              Parse `FROM` line in Dockerfile
                           │
                           ▼
          Is a new base image (major tag) available?
                           │
                 ┌─────────┴─────────┐
                 │                   │
                Yes                  No
                 │                   │
                 |                   ▼
                 |              Cancel Pipeline
                 ▼
             (re)-build
                 │
           ┌─────┴──────┐
           │            │
          Yes           No
           │            │
           ▼            ▼
  Search for matching   Continue pipeline
        minor-tag
           │
           ▼
    Store minor-tag as 
     additional tag
           |
           ▼
     Continue pipeline
```

The check-stage only runs on scheduled trigger.

You can find a demo repo here: https://gitlab.com/stack4ops/public/images/generic/cibuild-demo

### Commit trigger

Another common use case is rebuilding the image whenever new code is committed.
To enable this, simply uncomment the commit trigger event in .gitlab-ci.yaml.
Scheduled and commit-based triggers can be combined. 

The check-stage only runs on scheduled trigger.
....

# Build backend
----------
cibuild uses BuildKit as its build backend. It supports both docker buildx — which requires Docker-in-Docker — and the native buildctl client as front-end options. 

# Supported Buildx driver 
----------
* **docker-container**: https://docs.docker.com/reference/cli/docker/buildx/create/#docker-container-driver

* **kubernetes**: https://docs.docker.com/reference/cli/docker/buildx/create/#kubernetes-driver

* **remote**: https://docs.docker.com/reference/cli/docker/buildx/create/#remote-driver

The **default** docker driver is not supported because it provides limited isolation and lacks several key BuildKit features.

# GitLab Runner and buildkit:rootless

```
[GitLab Runner (Docker Executor)]
Host: Runner-Host
Host UID = irrelevant for BuildKit
│
└─ Job Container (image: buildkit:rootless)
   Container UID 1000  <-- Job runs as normal user
   HOME, volumes, and scripts behave normally
   │
   │  (User Namespace allowed in container)
   ▼
[RootlessKit creates User Namespace]
   Container UID 1000 --> Namespace UID 0 (mapped root)
   Other container UIDs mapped accordingly
   │
   ▼
[BuildKit rootless]
   Namespace UID 0  <-- sees itself as root
   → can perform root-level operations inside container
   → Container user (UID 1000) still owns HOME, volumes, scripts
   → Host sees only container processes as UID 1000 → safe
```

# Buildctl
----------
Buildctl is the native low-level client for buildkitd. It runs without a docker daemon. There is also a rootless mode available.

# Local Installation

# Deep Dive Sources
----------
- https://github.com/moby/buildkit
- https://github.com/moby/buildkit/tree/master/examples
- https://docs.docker.com/reference/cli/docker/buildx/
- https://docs.gitlab.com/ci/docker/using_buildkit/
- https://slsa.dev/