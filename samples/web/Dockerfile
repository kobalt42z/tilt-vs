# Non-.NET service with tilt-build: custom. devsuite registers nothing for it;
# Tiltfile.extend builds this image and live-syncs www/ into the container.
FROM nginx:1.27-alpine
COPY www/ /usr/share/nginx/html/
EXPOSE 80
