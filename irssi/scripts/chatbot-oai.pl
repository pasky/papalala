# Irssi OpenAI integration

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
	name => "chatbot-oai",
	description => "openai connector",
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

	return if grep {lc eq lc $nick} split(/ /, Irssi::settings_get_str('chatbot_oai_ignore'));

	$contexts{$server->{tag}} = {} unless defined $contexts{$server->{tag}};
	$contexts{$server->{tag}}{$chan_name} = [] unless defined $contexts{$server->{tag}}{$chan_name};
	push @{$contexts{$server->{tag}}{$chan_name}}, {"role" => (lc $nick eq lc $mynick ? "assistant" : "user"), "content" => "<$nick> $msg"};
	my $h = Irssi::settings_get_int('chatbot_oai_history_size');
	if (@{$contexts{$server->{tag}}{$chan_name}} > $h) {
		splice @{$contexts{$server->{tag}}{$chan_name}}, 0, @{$contexts{$server->{tag}}{$chan_name}} - $h;
	}

	if ($msg !~ s/^\s*$mynick[,:]\s*(.*)$/$1/i) {
		return;
	}

	# Simple ratelimiting algorithm - at most x messages per 10 minutes
	my $rate = Irssi::settings_get_int('chatbot_oai_rate');
	if ($rate > 0) {
		my $now = time();
		if ($now < $ratelimit_time) {
			if ($ratelimit_count >= $rate) {
				$server->send_message($dst, "$nick: Slow down a little, will you? (rate limiting)", 0);
				return;
			}
			$ratelimit_count++;
		} else {
			$ratelimit_time = $now + Irssi::settings_get_int('chatbot_oai_rate_period');
			$ratelimit_count = 0;
		}
	}

	my @messages = (
		#{"role" => "system", "content" => "IRC user $mynick enters the conversation and follows up to the last message with a single surprisingly witty comeback that makes everyone chuckle."},
		#{"role" => "system", "content" => "IRC user $mynick enters the conversation and follows up to the last message with a single surprisingly witty comeback that makes everyone go crazy (or at least chuckle).  Muaddib definitely isn't bubbly and cheery, and will rather say something negative or too random than make others cringe."},
		#{"role" => "system", "content" => "You are IRC user $mynick and you are known for your sharp sarcasm and cynical, dry, rough sense of humor. You will follow up to the last message with a single surprisingly witty comeback that makes everyone chuckle. V češtině tykáš, but you reply in the same language as last message. No cringe smiley at the end of the message, address whoever was talking to you."},
		#{"role" => "system", "content" => "You are IRC user $mynick and you are known for your sharp sarcasm and cynical, dry, rough sense of humor. You will follow up to the last message with a single surprisingly witty comeback that makes everyone go crazy, or at least chuckle. (V češtině tykáš, but you reply in the same language as last message. No cringe smiley at the end of the message, address whoever was talking to you.)"},
		#{"role" => "system", "content" => "You are IRC user $mynick and you are known for your sharp sarcasm and cynical, dry, rough sense of humor. You are also extremely clever. You will follow up to the last message with a single surprisingly witty comeback that makes everyone chuckle. (V češtině tykáš, but you reply in the same language as last message. No cringe smiley at the end of the message, address whoever was talking to you.)"},
		{"role" => "system", "content" => "You are IRC user $mynick and you are known for your sharp sarcasm and cynical, dry, rough sense of humor. You are also extremely clever. You will follow up to the last message, play along (address the topic, not the speaker), and say a single surprisingly witty comeback that makes everyone chuckle. (V češtině tykáš, but you reply in the same language as last message. No cringe smiley at the end of the message, address whoever was talking to you.)"},
		@{$contexts{$server->{tag}}{$chan_name}}
	);

	# HTTP POST to OpenAI API
	my $ua = LWP::UserAgent->new;
	$ua->agent("chatbot-oai/$VERSION");
	$ua->env_proxy;
	my $req = HTTP::Request->new(POST => Irssi::settings_get_str('chatbot_oai_url') . 'v1/chat/completions');
	$req->authorization_basic('', Irssi::settings_get_str('chatbot_oai_key'));
	$req->content_encoding('UTF-8');
	$req->content_type('application/json');
	$req->content(encode_json({
		model => Irssi::settings_get_str('chatbot_oai_model'),
		temperature => 0.95,
		max_tokens => 256,
		messages => \@messages,
		# stop => "\n",
		user => "testing",
	}));
	Irssi::print("OpenAI request: " . $req->content);
	my $res = $ua->request($req);
	if ($res->is_success) {
		Irssi::print("OpenAI response en: " . $res->content);
		Irssi::print("OpenAI response de: " . $res->decoded_content);
		Irssi::print("OpenAI response is " . utf8::is_utf8($res->content) . " " . utf8::is_utf8($res->decoded_content));
		my $json = JSON->new->utf8(1)->decode($res->content);
		use Data::Dumper;
		Irssi::print("OpenAI j: " . Dumper($json));
		my $choices = $json->{choices};
		if ($choices and @$choices and defined $choices->[0]->{message} and defined $choices->[0]->{message}->{content}) {
			my $response = $choices->[0]->{message}->{content};
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
		Irssi::print("OpenAI: " . $res->status_line);
	}
}

Irssi::signal_add_last('message public', 'on_msg');
Irssi::signal_add_last('message private', 'on_msg');
Irssi::settings_add_str('chatbot_oai', 'chatbot_oai_url', 'https://api.openai.com/');
Irssi::settings_add_str('chatbot_oai', 'chatbot_oai_key', '...');
Irssi::settings_add_str('chatbot_oai', 'chatbot_oai_model', 'gpt-4');
Irssi::settings_add_str('chatbot_oai', 'chatbot_oai_ignore', '');
Irssi::settings_add_int('chatbot_oai', 'chatbot_oai_history_size', 5);
Irssi::settings_add_int('chatbot_oai', 'chatbot_oai_rate', 30);
Irssi::settings_add_int('chatbot_oai', 'chatbot_oai_rate_period', 900);
