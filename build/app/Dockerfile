# Thin derived image: the upstream multi-arch grampsweb release plus a set of
# Gramps addons baked into the plugin directory. Built and pushed to ECR by the
# app pipeline; the GHCR base is pulled only here, at build time, inside
# CodeBuild -- never on the instance launch path.
#
# build/app/build.sh stages the selected addons under addons-stage/
# (driven by gramps_addons in tfvars), so this file is a pure FROM + COPY with
# no RUN. That lets buildx assemble both linux/arm64 and linux/amd64 by stacking
# one file-copy layer on each arch's base manifest, with no QEMU emulation.
ARG BASE_IMAGE
ARG GRAMPS_WEB_VERSION
FROM ${BASE_IMAGE}:${GRAMPS_WEB_VERSION}

# Gramps loads user plugins from <userdir>/gramps<MAJ><MIN>/plugins; the
# container's user dir is /root/.gramps. GRAMPS_SERIES (e.g. 60) is derived from
# the base image's Gramps version by the build script, so the path is never
# hand-maintained. COPY creates the intermediate directories.
ARG GRAMPS_SERIES
COPY addons-stage/ /root/.gramps/gramps${GRAMPS_SERIES}/plugins/

# Optional frontend override (gramps_web_repo/gramps_web_ref in tfvars): the
# build script stages that repo's built dist/ here; empty stage (the normal
# case) leaves the upstream frontend untouched. COPY merges over /app/static
# (the image's GRAMPSWEB_STATIC_PATH): index.html and the new hashed bundles
# land, and any stale upstream assets remain unreferenced until the next plain
# build. Kept as a COPY (no RUN) to preserve the QEMU-free multi-arch build.
COPY frontend-stage/ /app/static/
