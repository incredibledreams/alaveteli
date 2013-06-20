# models/track_mailer.rb:
# Emails which go to users who are tracking things.
#
# Copyright (c) 2008 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

class TrackMailer < ApplicationMailer
    def event_digest(user, email_about_things)
        @user, @email_about_things = user, email_about_things

        post_redirect = PostRedirect.new(
            :uri => user_url(user) + "#email_subscriptions",
            :user_id => user.id)
        post_redirect.save!
        @unsubscribe_url = confirm_url(:email_token => post_redirect.email_token)

        headers('Auto-Submitted' => 'auto-generated', # http://tools.ietf.org/html/rfc3834
                'Precedence' => 'bulk')# http://www.vbulletin.com/forum/project.php?issueid=27687 (Exchange hack)
        # 'Return-Path' => blackhole_email, 'Reply-To' => @from # we don't care about bounces for tracks
        # (We let it return bounces for now, so we can manually kill the tracks that bounce so Yahoo
        # etc. don't decide we are spammers.)

        mail(:from => contact_from_name_and_email,
             :to => user.name_and_email,
             :subject => _("Your {{site_name}} email alert", :site_name => site_name))
    end

    def contact_from_name_and_email
        "#{AlaveteliConfiguration::track_sender_name} <#{AlaveteliConfiguration::track_sender_email}>"
    end

    def self.record_sent_emails(email_about_things)
        # Given a list of track_things, alert_results, and xapian_objects
        # record that we've now sent those alerts to that user
        for track_thing, alert_results in email_about_things
            alert_results.each do |result|
                track_things_sent_email = TrackThingsSentEmail.new
                track_things_sent_email.track_thing_id = track_thing.id
                if result[:model].class.to_s == "InfoRequestEvent"
                    track_things_sent_email.info_request_event_id = result[:model].id
                else
                    raise "need to add other types to TrackMailer.alert_tracks (mark alerted)"
                end
                track_things_sent_email.save!
            end
        end
    end

    # Get the events that need alerting on for a given track_thing
    def self.get_alert_results(track_thing, one_week_ago, two_weeks_ago)
        # What have we alerted on already?
        #
        # We only use track_things_sent_emails records which are less than 14 days old.
        # In the search query loop below, we also only use items described in last 7 days.
        # An item described that recently definitely can't appear in track_things_sent_emails
        # earlier, so this is safe (with a week long margin of error). If the alerts break
        # for a whole week, then they will miss some items. Tough.
        done_info_request_events = {}
        tt_sent = track_thing.track_things_sent_emails.find(:all,
                                                            :conditions => ['created_at > ?',
                                                            two_weeks_ago])
        tt_sent.each do |t|
            if t.info_request_event_id
                done_info_request_events[t.info_request_event_id] = 1
            end
        end
        # Query for things in this track. We use described_at for the
        # ordering, so we catch anything new (before described), or
        # anything whose new status has been described.
        min_described_at = InfoRequestEvent.xapian_date_format(one_week_ago)
        if track_thing.created_at > min_described_at
            min_described_at =  InfoRequestEvent.xapian_date_format(track_thing.created_at)
        end
        query = track_thing.track_query + " described_at:#{min_described_at}.."

        xapian_object = ActsAsXapian::Search.new([InfoRequestEvent], query,
             :sort_by_prefix => 'described_at',
             :sort_by_ascending => true,
             :collapse_by_prefix => nil,
             :limit => 100)
        # Go through looking for unalerted things
        alert_results = []
        for result in xapian_object.results
            if result[:model].class.to_s != "InfoRequestEvent"
                raise "need to add other types to TrackMailer.alert_tracks (unalerted)"
            end
            next if done_info_request_events.include?(result[:model].id) # definitely already done

            # OK alert this one
            alert_results.push(result)
        end
        [alert_results, xapian_object]
    end

    def self.send_user_alert(user, now, one_week_ago, two_weeks_ago)
        email_about_things = []
        TrackThing.find(:all, :conditions => ["tracking_user_id = ? and track_medium = ?",
                                              user.id,
                                              'email_daily']).each do |track_thing|

            alert_results, xapian_object = get_alert_results(track_thing, one_week_ago, two_weeks_ago)

            # If there were more alerts for this track, then store them
            if alert_results.size > 0
                email_about_things.push([track_thing, alert_results, xapian_object])
            end
        end

        # If we have anything to send, then send everything for the user in one mail
        if email_about_things.size > 0
            # Send the email

            I18n.with_locale(user.get_locale) do
                TrackMailer.event_digest(user, email_about_things).deliver
            end
        end

        self.record_sent_emails(email_about_things)
        user.last_daily_track_email = now
        user.no_xapian_reindex = true
        user.save!
    end

    # Send email alerts for tracked things.  Never more than one email
    # a day, nor about events which are more than a week old, nor
    # events about which emails have been sent within the last two
    # weeks.
    # Useful query to run by hand to see how many alerts are due:
    #   User.count(:all, :conditions => [ "last_daily_track_email < ?", Time.now - 1.day ])
    def self.alert_tracks
        done_something = false
        now = Time.now()
        one_week_ago = now - 7.days
        two_weeks_ago = now - 14.days
        User.find_each(:conditions => [ "last_daily_track_email < ?",
                                         now - 1.day ]) do |user|
            next if !user.should_be_emailed? || !user.receive_email_alerts
            send_user_alert(user, now, one_week_ago, two_weeks_ago)
            done_something = true
        end
        return done_something
    end

    def self.alert_tracks_loop
        # Run alert_tracks in an endless loop, sleeping when there is nothing to do
        while true
            sleep_seconds = 1
            while !alert_tracks
                sleep sleep_seconds
                sleep_seconds *= 2
                sleep_seconds = 300 if sleep_seconds > 300
            end
        end
    end

end


