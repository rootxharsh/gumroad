# frozen_string_literal: true

Rpush.configure do |config|
  # Supported clients are :active_record and :redis
  config.client = :redis

  # Options passed to Redis.new
  config.redis_options = { url: "redis://#{ENV["RPUSH_REDIS_HOST"]}" }

  # Frequency in seconds to check for new notifications.
  config.push_poll = 2

  # The maximum number of notifications to load from the store every `push_poll` seconds.
  # If some notifications are still enqueued internally, Rpush will load the batch_size less
  # the number enqueued. An exception to this is if the service is able to receive multiple
  # notification payloads over the connection with a single write, such as APNs.
  config.batch_size = 100

  # Path to write PID file. Relative to current directory unless absolute.
  config.pid_file = Rails.root.join("tmp", "rpush.pid").to_s

  # Path to log file. Relative to current directory unless absolute.
  config.log_file = Rails.root.join("log", "rpush.log").to_s

  config.log_level = (defined?(Rails) && Rails.logger) ? Rails.logger.level : ::Logger::Severity::INFO

  # Define a custom logger.
  config.logger = (defined?(Rails) && Rails.logger) ? Rails.logger : ::Logger.new(STDOUT)
end

Rpush.reflect do |on|
  # Called with a Rpush::Apns::Feedback instance when feedback is received
  # from the APNs that a notification has failed to be delivered.
  # Further notifications should not be sent to the device.
  on.apns_feedback do |feedback|
    CleanupRpushDeviceService.new(feedback).process
  end

  # Called when a notification is queued internally for delivery.
  # The internal queue for each app runner can be inspected:
  #
  # Rpush::Daemon::AppRunner.runners.each do |app_id, runner|
  #   runner.app
  #   runner.queue_size
  # end
  #
  # on.notification_enqueued do |notification|
  # end

  def logger
    Rpush.config.logger
  end

  # Called when a notification is successfully delivered.
  on.notification_delivered do |notification|
    logger.info "Delivered notification #{notification.id} to #{notification.device_token} with message #{notification.alert}"
    Modis.with_connection do |redis|
      redis.expire(notification.key, 48.hours.to_i)
      redis.srem("rpush:notifications:all", notification.id)
    end
  end

  # Called when notification delivery failed.
  # Call 'error_code' and 'error_description' on the notification for the cause.
  on.notification_failed do |notification|
    logger.info "Delivery failed for notification #{notification.id} (#{notification.error_code} / #{notification.error_description})"
    Modis.with_connection do |redis|
      redis.expire(notification.key, 24.hours.to_i)
      redis.srem("rpush:notifications:all", notification.id)
    end
  end

  # Called when the notification delivery failed and only the notification ID
  # is present in memory.
  # on.notification_id_failed do |app, notification_id, error_code, error_description|
  # end

  # Called when a notification will be retried at a later date.
  # Call 'deliver_after' on the notification for the next delivery date
  # and 'retries' for the number of times this notification has been retried.
  # on.notification_will_retry do |notification|
  # end

  # Called when a notification will be retried and only the notification ID
  # is present in memory.
  # on.notification_id_will_retry do |app, notification_id, retry_after|
  # end

  # Called when a TCP connection is lost and will be reconnected.
  # on.tcp_connection_lost do |app, error|
  # end

  # Called for each recipient which successfully receives a notification. This
  # can occur more than once for the same notification when there are multiple
  # recipients.
  # on.gcm_delivered_to_recipient do |notification, registration_id|
  # end

  # Called for each recipient which fails to receive a notification. This
  # can occur more than once for the same notification when there are multiple
  # recipients. (do not handle invalid registration IDs here)
  # on.gcm_failed_to_recipient do |notification, error, registration_id|
  # end

  # Called when the GCM returns a canonical registration ID.
  # You will need to replace old_id with canonical_id in your records.
  # on.gcm_canonical_id do |old_id, canonical_id|
  # end

  # Called when the GCM returns a failure that indicates an invalid registration id.
  # You will need to delete the registration_id from your records.
  # on.gcm_invalid_registration_id do |app, error, registration_id|
  # end

  # Called when an SSL certificate will expire within 1 month.
  # Implement on.error to catch errors raised when the certificate expires.
  on.ssl_certificate_will_expire do |app, expiration_time|
    Bugsnag.notify(StandardError.new("App Certificate is about to expire soon #{expiration_time}"))
  end

  # Called when an SSL certificate has been revoked.
  on.ssl_certificate_revoked do |app, error|
    Bugsnag.notify(StandardError.new("App Certificate has been revoked #{error}"))
  end

  # Called when the ADM returns a canonical registration ID.
  # You will need to replace old_id with canonical_id in your records.
  # on.adm_canonical_id do |old_id, canonical_id|
  # end

  # Called when Failed to deliver to ADM. Check the 'reason' string for further
  # explanations.
  #
  # If the reason is the string 'Unregistered', you should remove
  # this registration id from your records.
  # on.adm_failed_to_recipient do |notification, registration_id, reason|
  # end

  # Called when Failed to deliver to WNS. Check the 'reason' string for further
  # explanations.
  # You should remove this uri from your records
  # on.wns_invalid_channel do |notification, uri, reason|
  # end

  # Called when an exception is raised.
  # on.error do |error|
  # end
end

# The rpush daemon needs all rpush apps to be present in Redis at start up.
# (See https://github.com/gumroad/web/pull/11372#discussion_r329752185)
if ENV["INITIALIZE_RPUSH_APPS"]
  Rails.application.config.after_initialize do
    PushNotificationService::Ios.creator_app
    PushNotificationService::Ios.consumer_app

    PushNotificationService::Android.consumer_app
  end
end
