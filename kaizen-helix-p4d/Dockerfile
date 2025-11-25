# Start FROM the existing build 
FROM hawkmothstudio/helix-p4d:latest

# Make our backup and verify  scripts executable
RUN chmod +x /utils/backup/*.sh \
    && chmod +x /utils/verify/*.sh \
    && chmod +x /utils/logger.sh
