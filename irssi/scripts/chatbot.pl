###### TODO
## add multiple server support

use strict;
use warnings;

use Irssi;
use Irssi::Irc;

use IO::Socket::INET;

use vars qw($VERSION %IRSSI);

$VERSION = '0.01';
%IRSSI = (
	authors => "Premysl 'Anydot' Hruby",
	contact => "dfenze\@gmail.com",
	name => "chatbot",
	description => "megahal connector",
);

our $megahal;

sub on_public {
	my ($server, $message, $nick, $hostmask, $channel) = @_;
	my $mynick = $server->{nick};
	my $request;

	return if grep {lc eq lc $nick} split(/ /, Irssi::settings_get_str('bot_megahal_ignore'));

	return unless $message =~ /^\s*$mynick[,:]\s*(.*)$/i;
	$server->send_message($channel, "$nick: ".megahal_response($1), 0); # send back to channel
}

sub megahal_response {
	my ($data) = @_;
	$data =~ s/\s+/ /;
	$data =~ s/\s*$/\n/;

	megahal_connect() unless defined $megahal;
	
	return ">> Can't connect to megahal, try latter or alert my master"
		unless defined $megahal;

	$megahal->printflush($data);
	my $response = $megahal->getline;

	if (! defined $response) {
		$megahal = undef;
		goto &megahal_response; ## restart
	}

	chomp($response);
	return $response;
}

sub megahal_connect {
	my $address = Irssi::settings_get_str('bot_megahal');
	$megahal = IO::Socket::INET->new(
		PeerAddr => $address,
		Type => SOCK_STREAM,
	);
}

Irssi::signal_add('message public', 'on_public');

Irssi::settings_add_str('bot', 'bot_megahal', 'localhost:4566');
Irssi::settings_add_str('bot', 'bot_megahal_ignore', '');
