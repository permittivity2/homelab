# The theme files, as served

`static.mailmasker.org/theme/v1/` is `/var/www/static/theme/v1/` on prod-homelab45
(10.20.2.189), served through the edges with `max-age=10`: a change there restyles
every app within seconds and needs no package build. Until post-cutover #94
(2026-11-18) nothing in the repo held these files; this directory is their
versioned copy from then on. Edit here, then publish:

    scp webtheme/static/theme/v1/theme.css 10.20.2.189:/var/www/static/theme/v1/theme.css

(gardner may write there: the directory is group www-data, mode 664.) The markup
the stylesheet styles is in `../templates/homelab/`, which IS packaged: a change
to it is a webtheme bump plus `install-orchestrators/webtheme-rollout.sh`.
