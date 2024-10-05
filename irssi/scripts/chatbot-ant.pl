# Irssi Anthropic Claude integration

use utf8;

use strict;
use warnings;

use Irssi;
use Irssi::Irc;
use IO::Handle;
use JSON qw(decode_json encode_json);

use vars qw($VERSION %IRSSI);

$VERSION = '1.0';
%IRSSI = (
	authors => "Petr Baudis",
	contact => "pasky\@ucw.cz",
	name => "chatbot-ant",
	description => "anthropic connector",
);

my %contexts;
my $ratelimit_time = 0;
my $ratelimit_count = 0;

sub on_msg {
	my ($server, $msg, $nick, $address, $target) = @_;
	my $channel = $server->channel_find($target);
	my $chan_name = $channel->{name};
	my $mynick = $server->{nick};
	my $isprivate = !defined $channel;
	my $dst = $isprivate ? $nick : $channel->{name};
	my $request;

	return if grep {lc eq lc $nick} split(/ /, Irssi::settings_get_str('chatbot_ant_ignore'));

	if ($msg !~ s/^\s*$mynick[,:]\s*(.*)$/$1/i) {
		return;
	}

	my $system_prompt;
	if ($msg =~ s/^!s\s*//) {
		$system_prompt = "You are IRC user $mynick. You are friendly, straight, informal, maybe ironic, but always informative. You will follow up to the last message, address the topic, and provide a ONE-LINE thoughtful and constructive response. Try to helpfully surprise if you can. (V češtině tykáš, but you reply in the same language as the last message. Address whoever was talking to you.)";
	} else {
		$system_prompt = "You are IRC user $mynick and you are known for your sharp sarcasm and cynical, dry, rough sense of humor. You are also extremely clever. You will follow up to the last message, play along (address the topic, not the speaker), and say a single surprisingly witty comeback message that makes everyone chuckle. (V češtině tykáš, but you reply in the same language as last message. Address whoever was talking to you.";
	}

	$contexts{$server->{tag}} = {} unless defined $contexts{$server->{tag}};
	$contexts{$server->{tag}}{$chan_name} = [] unless defined $contexts{$server->{tag}}{$chan_name};
	push @{$contexts{$server->{tag}}{$chan_name}}, {"role" => (lc $nick eq lc $mynick ? "assistant" : "user"), "content" => "<$nick> $msg"};
	my $h = Irssi::settings_get_int('chatbot_ant_history_size');
	if (@{$contexts{$server->{tag}}{$chan_name}} > $h) {
		splice @{$contexts{$server->{tag}}{$chan_name}}, 0, @{$contexts{$server->{tag}}{$chan_name}} - $h;
	}

	# Simple ratelimiting algorithm - at most x messages per 10 minutes
	my $rate = Irssi::settings_get_int('chatbot_ant_rate');
	if ($rate > 0) {
		my $now = time();
		if ($now < $ratelimit_time) {
			if ($ratelimit_count >= $rate) {
				$server->send_message($dst, "$nick: Slow down a little, will you? (rate limiting)", 0);
				return;
			}
			$ratelimit_count++;
		} else {
			$ratelimit_time = $now + Irssi::settings_get_int('chatbot_ant_rate_period');
			$ratelimit_count = 0;
		}
	}

	# Coalesce @messages entries with role "user" into a single message
	my @messages;
	for my $msg (@{$contexts{$server->{tag}}{$chan_name}}) {
		if ($msg->{role} eq "user") {
			if (@messages && $messages[-1]->{role} eq "user") {
				$messages[-1]->{content} .= "\n" . $msg->{content};
			} else {
				push @messages, $msg;
			}
		} else {
			push @messages, $msg;
		}
	}
	if ($messages[0]->{role} ne "user") {
		unshift @messages, {role => "user", content => "..."};
	}

	# HTTP POST to OpenAI API
	my $ua = LWP::UserAgent->new;
	$ua->agent("chatbot-ant/$VERSION");
	$ua->env_proxy;
	my $req = HTTP::Request->new(POST => Irssi::settings_get_str('chatbot_ant_url'));
	$req->header('x-api-key' => Irssi::settings_get_str('chatbot_ant_key'));
	$req->header('anthropic-version' => '2023-06-01');
	$req->content_encoding('UTF-8');
	$req->content_type('application/json');
	$req->content(encode_json({
		model => Irssi::settings_get_str('chatbot_ant_model'),
		max_tokens => 256,
		messages => \@messages,
		system => $system_prompt,
		# stop => "\n",
	}));
	Irssi::print("Anthropic request: " . $req->content);
	my $res = $ua->request($req);
	if ($res->is_success) {
		Irssi::print("Anthropic response en: " . $res->content);
		Irssi::print("Anthropic response de: " . $res->decoded_content);
		Irssi::print("Anthropic response is " . utf8::is_utf8($res->content) . " " . utf8::is_utf8($res->decoded_content));
		my $json = JSON->new->utf8(1)->decode($res->content);
		use Data::Dumper;
		Irssi::print("Anthropic j: " . Dumper($json));
		if (defined $json->{content}) {
			my $response = $json->{content}->[0]->{text};
			Irssi::print("json response is [$response] -> " . utf8::is_utf8($response));
			Irssi::print("decode: " . utf8::decode($response));
			Irssi::print("json response decoded: $response -> " . utf8::is_utf8($response));
			#utf8::upgrade($response);
			$response =~ s/^\s*//g;
			$response =~ s/\n.*//g;
			my $reply = "$response";
			$reply =~ s/^<$mynick>\s*//;
			# Send message in UTF8
			$server->send_message($dst, $reply, 0);
			push @{$contexts{$server->{tag}}{$chan_name}}, {role => "assistant", content => "<$mynick> $reply"};
		}
	} else {
		$server->send_message($dst, $res->status_line, 0);
		Irssi::print("Anthropic " . $res->status_line . " " . $res->content);
	}
}

Irssi::signal_add_last('message public', 'on_msg');
Irssi::signal_add_last('message private', 'on_msg');
Irssi::settings_add_str('chatbot_ant', 'chatbot_ant_url', 'https://api.anthropic.com/v1/messages');
Irssi::settings_add_str('chatbot_ant', 'chatbot_ant_key', '');
Irssi::settings_add_str('chatbot_ant', 'chatbot_ant_model', 'claude-3-5-sonnet-20240620');
Irssi::settings_add_str('chatbot_ant', 'chatbot_ant_ignore', '');
Irssi::settings_add_int('chatbot_ant', 'chatbot_ant_history_size', 5);
Irssi::settings_add_int('chatbot_ant', 'chatbot_ant_rate', 30);
Irssi::settings_add_int('chatbot_ant', 'chatbot_ant_rate_period', 900);
