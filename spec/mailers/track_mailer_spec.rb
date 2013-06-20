require File.expand_path(File.dirname(__FILE__) + '/../spec_helper')

describe TrackMailer do

    describe 'when sending email alerts for tracked things' do

        before do
            mail_mock = mock("mail")
            mail_mock.stub(:deliver)
            TrackMailer.stub!(:event_digest).and_return(mail_mock)
            Time.stub!(:now).and_return(Time.utc(2007, 11, 12, 23, 59))
        end

        it 'should ask for all the users whose last daily track email was sent more than a day ago' do
            expected_conditions = [ "last_daily_track_email < ?", Time.utc(2007, 11, 11, 23, 59)]
            User.should_receive(:find_each).with(:conditions => expected_conditions)
            TrackMailer.alert_tracks
        end

        describe 'for each user' do

            before do
                @user = mock_model(User, :no_xapian_reindex= => false,
                                         :last_daily_track_email= => true,
                                         :save! => true,
                                         :url_name => 'test-name',
                                         :get_locale => 'en',
                                         :should_be_emailed? => true)
                User.stub!(:find_each).and_yield(@user)
                @user.stub!(:receive_email_alerts).and_return(true)
                @user.stub!(:no_xapian_reindex=)
            end

            it 'should ask for any daily track things for the user' do
                expected_conditions = [ "tracking_user_id = ? and track_medium = ?", @user.id, 'email_daily' ]
                TrackThing.should_receive(:find).with(:all, :conditions => expected_conditions).and_return([])
                TrackMailer.alert_tracks
            end


            it 'should set the no_xapian_reindex flag on the user' do
                @user.should_receive(:no_xapian_reindex=).with(true)
                TrackMailer.alert_tracks
            end

            it 'should update the time of the user\'s last daily tracking email' do
                @user.should_receive(:last_daily_track_email=).with(Time.now)
                @user.should_receive(:save!)
                TrackMailer.alert_tracks
            end
            it 'should return true' do
                TrackMailer.alert_tracks.should == true
            end


            describe 'when getting alert results for a tracked thing' do

                before do
                    @track_things_sent_emails_array = []
                    @track_things_sent_emails_array.stub!(:find).and_return([]) # this is for the date range find (created in last 14 days)
                    @track_thing = mock_model(TrackThing, :track_query => 'test query',
                                                          :track_things_sent_emails => @track_things_sent_emails_array,
                                                          :created_at => Time.utc(2007, 10, 9, 23, 59))
                    TrackThing.stub!(:find).and_return([@track_thing])
                    @track_things_sent_email = mock_model(TrackThingsSentEmail, :save! => true,
                                                                                :track_thing_id= => true,
                                                                                :info_request_event_id= => true)
                    TrackThingsSentEmail.stub!(:new).and_return(@track_things_sent_email)
                    @xapian_search = mock('xapian search', :results => [])
                    @found_event = mock_model(InfoRequestEvent, :described_at => @track_thing.created_at + 1.day)
                    @search_result = {:model => @found_event}
                    ActsAsXapian::Search.stub!(:new).and_return(@xapian_search)
                    @one_week_ago = Time.utc(2007, 11, 12, 23, 59) - 7.days
                    @two_weeks_ago = Time.utc(2007, 11, 12, 23, 59) - 14.days
                end

                it 'should ask for the events returned by the tracking query described in the last week' do
                    ActsAsXapian::Search.should_receive(:new).with([InfoRequestEvent],
                        'test query described_at:20071105235900..',
                        :sort_by_prefix => 'described_at',
                        :sort_by_ascending => true,
                        :collapse_by_prefix => nil,
                        :limit => 100).and_return(@xapian_search)
                    TrackMailer.get_alert_results(@track_thing, @one_week_ago, @two_weeks_ago)
                end

                context 'when the track thing was set up less than a week ago' do

                    it 'should ask for the events returned by the query described since the track was set up' do
                        @track_thing.stub!(:created_at).and_return(Time.utc(2007, 11, 9, 23, 59))
                        ActsAsXapian::Search.should_receive(:new).with([InfoRequestEvent],
                            'test query described_at:20071109235900..',
                            :sort_by_prefix => 'described_at',
                            :sort_by_ascending => true,
                            :collapse_by_prefix => nil,
                            :limit => 100).and_return(@xapian_search)
                        TrackMailer.get_alert_results(@track_thing, @one_week_ago, @two_weeks_ago)
                    end

                end

                it 'should not include in the email any events that the user has already been sent a
                    tracking email about' do
                    sent_email = mock_model(TrackThingsSentEmail, :info_request_event_id => @found_event.id)
                    @track_things_sent_emails_array.stub!(:find).and_return([sent_email]) # this is for the date range find (created in last 14 days)
                    @xapian_search.stub!(:results).and_return([@search_result])
                    TrackMailer.should_not_receive(:event_digest)
                    TrackMailer.get_alert_results(@track_thing, @one_week_ago, @two_weeks_ago)
                end

                it 'should raise an error if a non-event class is returned by the tracking query' do
                    @xapian_search.stub!(:results).and_return([{:model => 'string class'}])
                    lambda{ TrackMailer.get_alert_results(@track_thing, @one_week_ago, @two_weeks_ago) }.should raise_error('need to add other types to TrackMailer.alert_tracks (unalerted)')
                end

            end

            describe 'when recording sent emails', :focus => true do

                it 'should record that a tracking email has been sent for each event that has been included in the email' do
                    @track_thing = mock_model(TrackThing)
                    @found_event = mock_model(InfoRequestEvent)
                    @search_result = {:model => @found_event}
                    sent_email = mock_model(TrackThingsSentEmail)
                    TrackThingsSentEmail.should_receive(:new).and_return(sent_email)
                    sent_email.should_receive(:track_thing_id=).with(@track_thing.id)
                    sent_email.should_receive(:info_request_event_id=).with(@found_event.id)
                    sent_email.should_receive(:save!)
                    TrackMailer.record_sent_emails([[@track_thing, [@search_result], mock('xapian search')]])
                end

            end

        end

        describe 'when a user should not be emailed' do
            before do
                @user = mock_model(User, :no_xapian_reindex= => false,
                                         :last_daily_track_email= => true,
                                         :save! => true,
                                         :url_name => 'test-name',
                                         :should_be_emailed? => false)
                User.stub!(:find_each).and_yield(@user)
                @user.stub!(:receive_email_alerts).and_return(true)
                @user.stub!(:no_xapian_reindex=)
            end

            it 'should not ask for any daily track things for the user' do
                expected_conditions = [ "tracking_user_id = ? and track_medium = ?", @user.id, 'email_daily' ]
                TrackThing.should_not_receive(:find).with(:all, :conditions => expected_conditions)
                TrackMailer.alert_tracks
            end

            it 'should not ask for any daily track things for the user if they have receive_email_alerts off but could otherwise be emailed' do
                @user.stub(:should_be_emailed?).and_return(true)
                @user.stub(:receive_email_alerts).and_return(false)
                expected_conditions = [ "tracking_user_id = ? and track_medium = ?", @user.id, 'email_daily' ]
                TrackThing.should_not_receive(:find).with(:all, :conditions => expected_conditions)
                TrackMailer.alert_tracks
            end

            it 'should not set the no_xapian_reindex flag on the user' do
                @user.should_not_receive(:no_xapian_reindex=).with(true)
                TrackMailer.alert_tracks
            end

            it 'should not update the time of the user\'s last daily tracking email' do
                @user.should_not_receive(:last_daily_track_email=).with(Time.now)
                @user.should_not_receive(:save!)
                TrackMailer.alert_tracks
            end
            it 'should return false' do
                TrackMailer.alert_tracks.should == false
            end
        end

    end

    describe 'delivering the email' do

        before :each do
          @post_redirect = mock_model(PostRedirect, :save! => true,
                                                    :email_token => "token")
          PostRedirect.stub!(:new).and_return(@post_redirect)
          ActionMailer::Base.deliveries = []
          @user = mock_model(User,
            :name_and_email => MailHandler.address_from_name_and_email('Tippy Test', 'tippy@localhost'),
            :url_name => 'tippy_test'
          )
          TrackMailer.event_digest(@user, []).deliver # no items in it email for minimal test
        end

        it 'should deliver one email, with right headers' do
            deliveries = ActionMailer::Base.deliveries
            if deliveries.size > 1 # debugging if there is an error
                deliveries.each do |d|
                    $stderr.puts "------------------------------"
                    $stderr.puts d.body
                    $stderr.puts "------------------------------"
                end
            end
            deliveries.size.should == 1
            mail = deliveries[0]

            mail['Auto-Submitted'].to_s.should == 'auto-generated'
            mail['Precedence'].to_s.should == 'bulk'

            deliveries.clear
        end

        context "force ssl is off" do
            # Force SSL is off in the tests. Since the code that selectively switches the protocols
            # is in the initialiser for Rails it's hard to test. Hmmm...
            # We could AlaveteliConfiguration.stub!(:force_ssl).and_return(true) but the config/environment.rb
            # wouldn't get reloaded

            it "should have http links in the email" do
                deliveries = ActionMailer::Base.deliveries
                deliveries.size.should == 1
                mail = deliveries[0]

                mail.body.should include("http://")
                mail.body.should_not include("https://")
            end
        end
    end

    describe "when sending alerts for a track" do

        before(:each) do
            load_raw_emails_data
            get_fixtures_xapian_index
            # set the time the comment event happened at to within the last week
            ire = info_request_events(:silly_comment_event)
            ire.created_at = Time.now - 3.days
            ire.save!
            update_xapian_index
        end

        it "should send alerts" do
            # Don't do clever locale-insertion-unto-URL stuff
            RoutingFilter.active = false

            TrackMailer.alert_tracks

            deliveries = ActionMailer::Base.deliveries
            deliveries.size.should == 1
            mail = deliveries[0]
            mail.body.should =~ /Alter your subscription/
            mail.to_addrs.first.to_s.should include(users(:silly_name_user).email)
            mail.body.to_s =~ /(http:\/\/.*\/c\/(.*))/
            mail_url = $1
            mail_token = $2

            mail.body.should_not =~ /&amp;/

            mail.body.should_not include('sent a request') # request not included
            mail.body.should_not include('sent a response') # response not included
            mail.body.should include('added an annotation') # comment included

            mail.body.should =~ /This a the daftest comment the world has ever seen/ # comment text included

            # Given we can't click the link, check the token is right instead
            post_redirect = PostRedirect.find_by_email_token(mail_token)
            expected_url = 'http://test.host/user/silly_emnameem#email_subscriptions'
            post_redirect.uri.should == expected_url

            # Check nothing more is delivered if we try again
            deliveries.clear
            TrackMailer.alert_tracks
            deliveries = ActionMailer::Base.deliveries
            deliveries.size.should == 0

            # Restore the routing filters
            RoutingFilter.active = true
        end

        it "should send localised alerts" do
            user = users(:silly_name_user)
            user.locale = "es"
            user.save!
            TrackMailer.alert_tracks
            deliveries = ActionMailer::Base.deliveries
            mail = deliveries[0]
            mail.body.should include('el equipo de ')
        end
    end
end



