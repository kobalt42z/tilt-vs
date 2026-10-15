FROM alpine:3.20 AS base
ARG GREETING=unset
RUN echo "greeting=$GREETING" > /greeting
FROM base AS final
CMD ["sleep","infinity"]
