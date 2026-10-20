FROM coturn/coturn:4.18.0-r0
USER 0
# The upstream binary carries a file capability for privileged ports. Copying
# it without that xattr permits exec with an empty capability bounding set;
# this deployment listens exclusively on unprivileged ports.
RUN cp /usr/bin/turnserver /usr/local/bin/openu60-turnserver
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/openu60-turnserver"]
