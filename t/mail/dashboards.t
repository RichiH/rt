use strict;
use warnings;

use RT::Test tests => 181;
use Test::Warn;
use RT::Dashboard::Mailer;

my ($baseurl, $m) = RT::Test->started_ok;
ok($m->login, 'logged in');

sub create_dashboard {
    my ($baseurl, $m) = @_;
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    $m->get_ok($baseurl . '/Dashboards/Modify.html?Create=1');
    $m->form_name('ModifyDashboard');
    $m->field('Name' => 'Testing!');
    $m->click_button(value => 'Create');
    $m->title_is('Modify the dashboard Testing!');

    $m->follow_link_ok({text => 'Content'});
    $m->title_is('Modify the content of dashboard Testing!');

    my $form = $m->form_name('Dashboard-Searches-body');
    my @input = $form->find_input('Searches-body-Available');
    my ($dashboards_component) =
        map { ( $_->possible_values )[1] }
        grep { ( $_->value_names )[1] =~ /Dashboards/ } @input;
    $form->value('Searches-body-Available' => $dashboards_component );
    $m->click_button(name => 'add');
    $m->content_contains('Dashboard updated');

    $m->follow_link_ok({text => 'Show'});
    $m->title_is('Testing! Dashboard');
    $m->content_contains('My dashboards');
    $m->content_like(qr{<a href="/Dashboards/\d+/Testing!">Testing!</a>});

}

sub create_subscription {
    my ($baseurl, $m, %fields) = @_;
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    # create a subscription
    $m->follow_link_ok({text => 'Subscription'});
    $m->title_is('Subscribe to dashboard Testing!');
    $m->form_name('SubscribeDashboard');
    $m->set_fields(%fields);
    $m->click_button(name => 'Save');
    $m->content_contains("Subscribed to dashboard Testing!");
}

sub get_dash_sub_ids {
    my $user = RT::User->new(RT->SystemUser);
    $user->Load('root');
    ok($user->Id, 'loaded user');
    my ($subscription) = $user->Attributes->Named('Subscription');
    my $subscription_id = $subscription->Id;
    ok($subscription_id, 'loaded subscription');
    my $dashboard_id = $subscription->SubValue('DashboardId');
    ok($dashboard_id, 'got dashboard id');


    return ($dashboard_id, $subscription_id);
}

# first, create and populate a dashboard
create_dashboard($baseurl, $m);

# now test the mailer

# without a subscription..
RT::Dashboard::Mailer->MailDashboards();

my @mails = RT::Test->fetch_caught_mails;
is @mails, 0, 'no mail yet';

RT::Dashboard::Mailer->MailDashboards(
    All => 1,
);

@mails = RT::Test->fetch_caught_mails;
is @mails, 0, "no mail yet since there's no subscription";

create_subscription($baseurl, $m,
    Frequency => 'daily',
    Hour      => '06:00',
);

my ($dashboard_id, $subscription_id) = get_dash_sub_ids();

sub produces_dashboard_mail_ok { # {{{
    my %args = @_;
    my $subject = delete $args{Subject};

    local $Test::Builder::Level = $Test::Builder::Level + 1;

    RT::Dashboard::Mailer->MailDashboards(%args);

    my @mails = RT::Test->fetch_caught_mails;
    is @mails, 1, "got a dashboard mail";

    my $mail = parse_mail( $mails[0] );
    is($mail->head->get('Subject'), $subject);
    is($mail->head->get('From'), "root\n");
    is($mail->head->get('X-RT-Dashboard-Id'), "$dashboard_id\n");
    is($mail->head->get('X-RT-Dashboard-Subscription-Id'), "$subscription_id\n");

    SKIP: {
        skip 'Weird MIME failure', 2;
        my $body = $mail->stringify_body;
        like($body, qr{My dashboards});
        like($body, qr{<a href="http://[^/]+/Dashboards/\d+/Testing!">Testing!</a>});
    };
} # }}}

sub produces_no_dashboard_mail_ok { # {{{
    my %args = @_;
    my $name = delete $args{Name};

    local $Test::Builder::Level = $Test::Builder::Level + 1;

    RT::Dashboard::Mailer->MailDashboards(%args);

    @mails = RT::Test->fetch_caught_mails;
    is @mails, 0, $name;
} # }}}

sub delete_dashboard { # {{{
    my $dashboard_id = shift;
    # delete the dashboard and make sure we get exactly one subscription failure
    # notice
    my $dashboard = RT::Dashboard->new(RT::CurrentUser->new('root'));
    my ($ok, $msg) = $dashboard->LoadById($dashboard_id);
    ok($ok, $msg);

    ($ok, $msg) = $dashboard->Delete;
    ok($ok, $msg);
} # }}}

my $good_time = 1290423660; # 6:01 EST on a monday
my $bad_time  = 1290427260; # 7:01 EST on a monday

my $expected_subject = "[example.com] Daily Dashboard: Testing!\n";

produces_dashboard_mail_ok(
    Time => $good_time,
    Subject => $expected_subject,
);

produces_dashboard_mail_ok(
    All => 1,
    Subject => $expected_subject,
);

produces_dashboard_mail_ok(
    All  => 1,
    Time => $good_time,
    Subject => $expected_subject,
);

produces_dashboard_mail_ok(
    All  => 1,
    Time => $bad_time,
    Subject => $expected_subject,
);


produces_no_dashboard_mail_ok(
    Name   => "no dashboard mail it's a dry run",
    All    => 1,
    DryRun => 1,
);

produces_no_dashboard_mail_ok(
    Name   => "no dashboard mail it's a dry run",
    Time   => $good_time,
    DryRun => 1,
);

produces_no_dashboard_mail_ok(
    Name => "no mail because it's the wrong time",
    Time => $bad_time,
);

@mails = RT::Test->fetch_caught_mails;
is(@mails, 0, "no mail leftover");


$m->no_warnings_ok;
RT::Test->stop_server;
RT->Config->Set('DashboardSubject' => 'a %s b %s c');
RT->Config->Set('DashboardAddress' => 'dashboard@example.com');
RT->Config->Set('EmailDashboardRemove' => (qr/My dashboards/, "Testing!"));
($baseurl, $m) = RT::Test->started_ok;

RT::Dashboard::Mailer->MailDashboards(All => 1);
@mails = RT::Test->fetch_caught_mails;
is(@mails, 1, "one mail");
my $mail = parse_mail($mails[0]);
is($mail->head->get('Subject'), "[example.com] a Daily b Testing! c\n");
is($mail->head->get('From'), "dashboard\@example.com\n");
is($mail->head->get('X-RT-Dashboard-Id'), "$dashboard_id\n");
is($mail->head->get('X-RT-Dashboard-Subscription-Id'), "$subscription_id\n");

SKIP: {
    skip 'Weird MIME failure', 2;
    my $body = $mail->stringify_body;
    unlike($body, qr{My dashboards});
    unlike($body, qr{Testing!});
};

delete_dashboard($dashboard_id);

RT::Dashboard::Mailer->MailDashboards(All => 1);
@mails = RT::Test->fetch_caught_mails;
is(@mails, 0, "no mail because the subscription is deleted");

RT::Test->stop_server;
RT::Test->clean_caught_mails;
RT->Config->Set('EmailDashboardRemove' => ());
RT->Config->Set('DashboardAddress' => 'root');
($baseurl, $m) = RT::Test->started_ok;
$m->login;
create_dashboard($baseurl, $m);
create_subscription($baseurl, $m,
    Frequency => 'weekly',
    Hour => '06:00',
);

($dashboard_id, $subscription_id) = get_dash_sub_ids();

# bump $bad_time to Tuesday
$bad_time = $good_time + 86400;

produces_dashboard_mail_ok(
    Time    => $good_time,
    Subject =>  "[example.com] a Weekly b Testing! c\n",
);

produces_no_dashboard_mail_ok(
    Name    => "no mail because it's the wrong time",
    Time    => $bad_time,
);

@mails = RT::Test->fetch_caught_mails;
is(@mails, 0, "no mail leftover");

$m->no_warnings_ok;
RT::Test->stop_server;
RT->Config->Set('DashboardSubject' => 'a %s b %s c');
RT->Config->Set('DashboardAddress' => 'dashboard@example.com');
RT->Config->Set('EmailDashboardRemove' => (qr/My dashboards/, "Testing!"));
($baseurl, $m) = RT::Test->started_ok;

delete_dashboard($dashboard_id);

RT::Test->clean_caught_mails;

RT::Test->stop_server;

RT->Config->Set('EmailDashboardRemove' => ());
RT->Config->Set('DashboardAddress' => 'root');
($baseurl, $m) = RT::Test->started_ok;
$m->login;
create_dashboard($baseurl, $m);
create_subscription($baseurl, $m,
    Frequency => 'm-f',
    Hour => '06:00',
);

($dashboard_id, $subscription_id) = get_dash_sub_ids();

# bump $bad_time back to Sunday
$bad_time = $good_time - 86400;

produces_dashboard_mail_ok(
    Time    => $good_time,
    Subject =>  "[example.com] a Weekday b Testing! c\n",
);

produces_no_dashboard_mail_ok(
    Name    => "no mail because it's the wrong time",
    Time    => $bad_time,
);

produces_no_dashboard_mail_ok(
    Name    => "no mail because it's the wrong time",
    Time    => $bad_time - 86400, # saturday
);

produces_dashboard_mail_ok(
    Time    => $bad_time - 86400 * 2, # friday
    Subject =>  "[example.com] a Weekday b Testing! c\n",
);


@mails = RT::Test->fetch_caught_mails;
is(@mails, 0, "no mail leftover");

$m->no_warnings_ok;
RT::Test->stop_server;
RT->Config->Set('DashboardSubject' => 'a %s b %s c');
RT->Config->Set('DashboardAddress' => 'dashboard@example.com');
RT->Config->Set('EmailDashboardRemove' => (qr/My dashboards/, "Testing!"));
($baseurl, $m) = RT::Test->started_ok;

delete_dashboard($dashboard_id);

RT::Test->clean_caught_mails;

RT::Test->stop_server;

RT->Config->Set('EmailDashboardRemove' => ());
RT->Config->Set('DashboardAddress' => 'root');
($baseurl, $m) = RT::Test->started_ok;
$m->login;
create_dashboard($baseurl, $m);
create_subscription($baseurl, $m,
    Frequency => 'monthly',
    Hour => '06:00',
);

($dashboard_id, $subscription_id) = get_dash_sub_ids();

$good_time = 1291201200;        # dec 1
$bad_time = $good_time - 86400; # day before (i.e. different month)

produces_dashboard_mail_ok(
    Time    => $good_time,
    Subject =>  "[example.com] a Monthly b Testing! c\n",
);

produces_no_dashboard_mail_ok(
    Name    => "no mail because it's the wrong time",
    Time    => $bad_time,
);


@mails = RT::Test->fetch_caught_mails;
is(@mails, 0, "no mail leftover");

$m->no_warnings_ok;
RT::Test->stop_server;
RT->Config->Set('DashboardSubject' => 'a %s b %s c');
RT->Config->Set('DashboardAddress' => 'dashboard@example.com');
RT->Config->Set('EmailDashboardRemove' => (qr/My dashboards/, "Testing!"));
($baseurl, $m) = RT::Test->started_ok;

delete_dashboard($dashboard_id);

RT::Test->clean_caught_mails;

RT::Test->stop_server;

RT->Config->Set('EmailDashboardRemove' => ());
RT->Config->Set('DashboardAddress' => 'root');
($baseurl, $m) = RT::Test->started_ok;
$m->login;
create_dashboard($baseurl, $m);
create_subscription($baseurl, $m,
    Frequency => 'never',
);

($dashboard_id, $subscription_id) = get_dash_sub_ids();

produces_no_dashboard_mail_ok(
    Name    => "mail should never get sent",
    Time    => $bad_time,
);

