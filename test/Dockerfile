# Minimal image for .github/workflows/selftest.yml. Two stages so that `target` has
# something to choose from: `runner` is the right one, `wrong` is caught by the smoke test.
FROM busybox:1.37 AS base
RUN mkdir /www

FROM base AS wrong
RUN echo '{"revision":"wrong"}' > /www/version.json
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]

FROM base AS runner
ARG APP_REVISION=dev
ARG APP_BUILT_AT=unknown
ARG SELFTEST_GREETING=missing
RUN printf '{"revision":"%s","builtAt":"%s","greeting":"%s"}\n' \
      "$APP_REVISION" "$APP_BUILT_AT" "$SELFTEST_GREETING" > /www/version.json
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
