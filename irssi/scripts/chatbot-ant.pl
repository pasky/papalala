# Irssi Anthropic Claude integration

use utf8;

use strict;
use warnings;

use Encode;
use Irssi;
use Irssi::Irc;
use IO::Handle;
use IPC::Open2;
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

sub update_history {
	my ($server_tag, $chan_name, $msg, $nick, $mynick, $is_response) = @_;
	$contexts{$server_tag} = {} unless defined $contexts{$server_tag};
	$contexts{$server_tag}{$chan_name} = [] unless defined $contexts{$server_tag}{$chan_name};

	push @{$contexts{$server_tag}{$chan_name}},
		 {"role" => (lc $nick eq lc $mynick ? "assistant" : "user"),
		  "content" => Encode::decode_utf8("<$nick> $msg")};

	my $h = Irssi::settings_get_int('chatbot_ant_history_size');
	if (@{$contexts{$server_tag}{$chan_name}} > $h) {
		splice @{$contexts{$server_tag}{$chan_name}}, 0, @{$contexts{$server_tag}{$chan_name}} - $h;
	}
}

sub rate_limit {
	my ($server, $chan_name, $nick) = @_;
	my $rate = Irssi::settings_get_int('chatbot_ant_rate');
	return 1 unless $rate > 0;

	my $now = time();
	if ($now < $ratelimit_time) {
		if ($ratelimit_count >= $rate) {
			$server->send_message($chan_name, "$nick: Slow down a little, will you? (rate limiting)", 0);
			return 0;
		}
		$ratelimit_count++;
	} else {
		$ratelimit_time = $now + Irssi::settings_get_int('chatbot_ant_rate_period');
		$ratelimit_count = 0;
	}
	return 1;
}

sub perplexity_call {
	my ($server, $chan_name, $nick, $mynick, $context) = @_;
	my $query = join(" | ", map { $_->{content} } @$context) . " <REPLY IN ONE LINE>";
	Irssi::print("Perplexity: " . $query);
	my $key = Irssi::settings_get_str('chatbot_ant_perplexity_key');

	my ($py_out, $py_in);
	open2($py_out, $py_in, "PERPLEXITY_API_KEY=$key python3 -c 'import sys; from plexsearch import perform_search; print(perform_search(sys.stdin.read(), show_citations=True))'") or die "Failed to open pipe: $!";
	binmode($py_in, ":utf8");
	binmode($py_out, ":utf8");
	print $py_in $query;
	close($py_in);
	my $reply = do { local $/; <$py_out> };
	chomp($reply);
	close($py_out);

	Irssi::print("Reply raw: <" . $reply . ">");
	$reply =~ s/\n/  /g;
	$reply =~ s/   */  /g;
	if ($reply =~ s/References:  *(.*)//g) {
		my $refs = $1;
		$server->send_message($chan_name, "$nick: $reply", 0);
		$server->send_message($chan_name, "$nick: $refs", 0);
		return $reply;
	}
	$server->send_message($chan_name, "$nick: $reply", 0);
	return $reply;
}

sub deepseek_call {
	my ($server, $chan_name, $nick, $mynick, $context, $system_prompt) = @_;
	my $ua = LWP::UserAgent->new;
	$ua->agent("chatbot-ant/$VERSION");
	$ua->env_proxy;
	my $req = HTTP::Request->new(POST => Irssi::settings_get_str('chatbot_ant_deepseek_url'));
	$req->header('Authorization' => 'Bearer ' . Irssi::settings_get_str('chatbot_ant_deepseek_key'));
	$req->content_encoding('UTF-8');
	$req->content_type('application/json');

	# Coalesce user messages
	my @messages;
	for my $msg (@$context) {
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

	$req->content(encode_json({
		model => Irssi::settings_get_str('chatbot_ant_deepseek_model'),
		messages => [
			{role => "system", content => $system_prompt},
			@messages
		],
		max_tokens => 256,
		temperature => 0.7,
	}));

	Irssi::print("DeepSeek request: " . $req->content);
	my $res = $ua->request($req);
	if ($res->is_success) {
		my $json = JSON->new->utf8(1)->decode($res->content);
		use Data::Dumper;
		Irssi::print("DeepSeek j: " . Dumper($json));
		if (defined $json->{choices} && @{$json->{choices}} > 0) {
			my $response = $json->{choices}[0]{message}{content};
			$response =~ s/^\s*//g;
			$response =~ s/\n/|/g;
			$response =~ s/^<$mynick>\s*//;
			
			# Handle reasoning trace if present
			if (defined $json->{choices}[0]{message}{reasoning_content}) {
				my $trace_file = join('', map {('a'..'z')[rand 26]} (1..6)) . ".txt";
				my $trace_dir = Irssi::settings_get_str('chatbot_ant_rtraces_dir');
				
				# Create directory if it doesn't exist
				unless (-d $trace_dir) {
					mkdir $trace_dir or do {
						Irssi::print("Failed to create trace directory: $!");
						return undef;
					};
				}
				
				# Write reasoning trace
				if (open(my $fh, '>:utf8', "$trace_dir/$trace_file")) {
					print $fh $json->{choices}[0]{message}{reasoning_content};
					close $fh;
					
					# Append trace URL to response
					my $trace_url = Irssi::settings_get_str('chatbot_ant_rtraces_url');
					$response .= " (" . $trace_url . "/" . $trace_file . ")";
				} else {
					Irssi::print("Failed to write reasoning trace: $!");
				}
			}
			
			$server->send_message($chan_name, $response, 0);
			return $response;
		}
	} else {
		$server->send_message($chan_name, $res->status_line, 0);
		Irssi::print("DeepSeek " . $res->status_line . " " . $res->content);
		return undef;
	}
}

sub claude_call {
	my ($server, $chan_name, $nick, $mynick, $context, $system_prompt) = @_;
	my $ua = LWP::UserAgent->new;
	$ua->agent("chatbot-ant/$VERSION");
	$ua->env_proxy;
	my $req = HTTP::Request->new(POST => Irssi::settings_get_str('chatbot_ant_url'));
	$req->header('x-api-key' => Irssi::settings_get_str('chatbot_ant_key'));
	$req->header('anthropic-version' => '2023-06-01');
	$req->content_encoding('UTF-8');
	$req->content_type('application/json');

	# Coalesce user messages
	my @messages;
	for my $msg (@$context) {
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

	$req->content(encode_json({
		model => Irssi::settings_get_str('chatbot_ant_model'),
		max_tokens => 256,
		messages => \@messages,
		system => $system_prompt,
	}));
	Irssi::print("Anthropic request: " . $req->content);
	my $res = $ua->request($req);
	if ($res->is_success) {
		my $json = JSON->new->utf8(1)->decode($res->content);
		use Data::Dumper;
		Irssi::print("Anthropic j: " . Dumper($json));
		if (defined $json->{content}) {
			my $response = $json->{content}->[0]->{text};
			$response =~ s/^\s*//g;
			$response =~ s/\n.*//g;
			$response =~ s/^<$mynick>\s*//;
			$server->send_message($chan_name, $response, 0);
			return $response;
		}
	} else {
		$server->send_message($chan_name, $res->status_line, 0);
		Irssi::print("Anthropic " . $res->status_line . " " . $res->content);
		return undef;
	}
}

sub on_msg {
	my ($server, $msg, $nick, $address, $target) = @_;
	my $channel = $server->channel_find($target);
	my $isprivate = !defined $channel;
	my $chan_name = $isprivate ? $nick : $channel->{name};
	my $mynick = $server->{nick};

	return if grep {lc eq lc $nick} split(/ /, Irssi::settings_get_str('chatbot_ant_ignore'));

	# Check if we should respond and clean up message
	my $cleaned_msg = $msg;
	return if $cleaned_msg !~ s/^\s*$mynick[,:]\s*(.*)$/$1/i;

	# Update history before rate limiting to maintain context
	update_history($server->{tag}, $chan_name, $msg, $nick, $mynick, 0);

	# Check rate limiting
	return unless rate_limit($server, $chan_name, $nick);

	# Process message and call appropriate API
	my $reply;
	if ($cleaned_msg =~ s/^!p\s*//) {
		$reply = perplexity_call($server, $chan_name, $nick, $mynick,
					 $contexts{$server->{tag}}{$chan_name});
	} else {
		my $system_prompt;
		if ($cleaned_msg =~ s/^!s\s*//) {
			$system_prompt = "You are IRC user $mynick. You are friendly, straight, informal, maybe ironic, but always informative. You will follow up to the last message, address the topic, and provide a ONE-LINE thoughtful and constructive response. Try to helpfully surprise if you can. (V češtině tykáš, but you reply in the same language as the last message. Address whoever was talking to you.)";
		} else {
			$system_prompt = "You are IRC user $mynick and you are known for your sharp sarcasm and cynical, dry, rough sense of humor. You are also extremely clever. You will follow up to the last message, play along (address the topic, not the speaker), and say a single surprisingly witty comeback message that makes everyone chuckle. (V češtině tykáš, but you reply in the same language as last message. Address whoever was talking to you.";
		}
		if ($cleaned_msg =~ s/^!d\s*//) {
			$reply = deepseek_call($server, $chan_name, $nick, $mynick,
						$contexts{$server->{tag}}{$chan_name}, $system_prompt);
		} else {
			$reply = claude_call($server, $chan_name, $nick, $mynick,
					     $contexts{$server->{tag}}{$chan_name}, $system_prompt);
		}
	}

	# Update history with response if we got one
	if ($reply) {
		update_history($server->{tag}, $chan_name, Encode::encode_utf8($reply), $mynick, $mynick, 1);
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
Irssi::settings_add_str('chatbot_ant', 'chatbot_ant_perplexity_key', '');
Irssi::settings_add_str('chatbot_ant', 'chatbot_ant_deepseek_url', 'https://api.deepseek.com/v1/chat/completions');
Irssi::settings_add_str('chatbot_ant', 'chatbot_ant_deepseek_key', '');
Irssi::settings_add_str('chatbot_ant', 'chatbot_ant_rtraces_dir', '/tmp/chatbot-ant-rtraces');
Irssi::settings_add_str('chatbot_ant', 'chatbot_ant_rtraces_url', 'https://example.com/rtraces');
Irssi::settings_add_str('chatbot_ant', 'chatbot_ant_deepseek_model', 'deepseek-reasoner');
