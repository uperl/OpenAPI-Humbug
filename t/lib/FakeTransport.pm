package FakeTransport;

use 5.042;
use warnings;
use JSON::PP ();
use OpenAPI::Humbug;
use Exporter qw( import );

our @EXPORT = qw( fake_client );

# An in-memory transport: each command is decoded and handed to a responder, whose answer
# (a hash reference to encode, or a raw line) is the reply.  No process is involved.

my $json = JSON::PP->new->utf8->canonical;

sub new ($class, %args) {
  return bless {
    responder          => $args{responder},
    ends_with_shutdown => $args{ends_with_shutdown} // 1,
    sent               => [],
    open               => 1,
  }, $class;
}

sub sent               ($self) { $self->{sent} }
sub aborted            ($self) { $self->{aborted} }
sub is_open            ($self) { $self->{open} }
sub ends_with_shutdown ($self) { $self->{ends_with_shutdown} }
sub stderr             ($self) { 'fake stderr' }
sub close              ($self, $grace) { $self->{open} = 0; return 1 }
sub abort              ($self) { $self->{open} = 0; $self->{aborted} = 1; return 0 }

sub exchange ($self, $line, $timeout) {
  die "exchange on a closed fake transport\n" unless $self->{open};
  my $command = $json->decode($line);
  push $self->{sent}->@*, $command;
  my $reply = $self->{responder}->($command, $line);
  return ref $reply ? $json->encode($reply) . "\n" : $reply;
}

# the default sidecar: initialize and shutdown succeed, validate gets an empty valid result
sub default_reply ($command) {
  my $id = $command->{id};
  return { id => $id, type => 'result', result => { protocol_version => 1, specification => { openapi_version => '3.1.0', title => 'Fake' } } }
    if $command->{type} eq 'initialize';
  return { id => $id, type => 'result', result => {} } if $command->{type} eq 'shutdown';
  return { id => $id, type => 'result', result => { valid => JSON::PP::true } };
}

# a client on a fake transport; validate replies come from $responder (default replies otherwise)
sub fake_client (%args) {
  my $responder = delete $args{responder} // sub ($command, $line) { undef };
  my $transport = FakeTransport->new(
    responder => sub ($command, $line) {
      return $responder->($command, $line) // default_reply($command);
    },
    map { $_ => $args{$_} } grep { exists $args{$_} } qw( ends_with_shutdown ),
  );
  delete $args{ends_with_shutdown};
  local $FakeClient::transport = $transport;
  my $client = FakeClient->new(spec => 'corpus/pets.yaml', %args);
  return ($client, $transport);
}

package FakeClient {
  use parent -norequire, 'OpenAPI::Humbug';
  our $transport;
  sub _build_transport ($self) { $transport }
}
