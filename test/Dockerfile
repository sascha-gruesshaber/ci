# Mini-Image für .github/workflows/selftest.yml. Zwei Stufen, damit `target` etwas zu
# wählen hat: `runner` ist die richtige, `falsch` fällt im Rauchtest auf.
FROM busybox:1.37 AS base
RUN mkdir /www

FROM base AS falsch
RUN echo '{"revision":"falsch"}' > /www/version.json
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]

FROM base AS runner
ARG APP_REVISION=dev
ARG APP_BUILT_AT=unknown
ARG SELFTEST_GRUSS=fehlt
RUN printf '{"revision":"%s","builtAt":"%s","gruss":"%s"}\n' \
      "$APP_REVISION" "$APP_BUILT_AT" "$SELFTEST_GRUSS" > /www/version.json
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
