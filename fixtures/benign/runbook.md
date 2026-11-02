# Restarting the reporting service

Follow these steps in order. Do not skip the backup.

1. Log in to the admin console and open the Services page.
2. Click Backup now and wait until the status shows Complete.
3. Select the reporting service, then click Stop. Wait for the status to read Stopped.
4. Run the migration command shown on the page. If it prints an error, copy the message and send it to the on-call engineer.
5. Click Start. Open the dashboard and confirm that the daily report loads within a minute.
6. If the report does not load, stop the service again and restore the backup you made in step 2.

Always record the time of the restart in the shared log.
