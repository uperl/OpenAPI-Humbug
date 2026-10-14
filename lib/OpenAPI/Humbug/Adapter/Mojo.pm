package OpenAPI::Humbug::Adapter::Mojo;

use 5.042;
use warnings;
use OpenAPI::Humbug::Error;
use namespace::autoclean;

# ABSTRACT: Internal conversion of Mojolicious messages for OpenAPI::Humbug
# VERSION

=head1 SYNOPSIS

 # internal; pass Mojo objects to OpenAPI::Humbug's validate instead
 $humbug->validate($tx);
 $humbug->validate(request => $tx->req, response => $tx->res);

=head1 DESCRIPTION

B<This module is internal to L<OpenAPI::Humbug> and is not a supported interface.>  It converts
L<Mojo::Message::Request>, L<Mojo::Message::Response> and L<Mojo::Transaction::HTTP> objects to the
request and response hashes that L<OpenAPI::Humbug/validate> accepts.  It is loaded only when one of
those objects is passed, and does not load Mojolicious itself.  The calling conventions and what is
preserved are documented in L<OpenAPI::Humbug/MOJOLICIOUS>.

The objects are only read, never changed.  Methods that would change them, such as
C<fix_headers>, C<build_body> or C<to_string>, are not called.

=head1 METHODS

=head2 request

 my $hash = OpenAPI::Humbug::Adapter::Mojo->request($req);

=head2 response

 my $hash = OpenAPI::Humbug::Adapter::Mojo->response($res, $request_method);

The request method, if known, is used to tell an absent response body from an empty one.

=head2 transaction

 my %args = OpenAPI::Humbug::Adapter::Mojo->transaction($tx);

C<request>, and C<response> if the response is complete (see L</response_complete>).

=head2 response_complete

 my $bool = OpenAPI::Humbug::Adapter::Mojo->response_complete($res);

True if the response has a status code and Mojo has finished it: received it in full (client side)
or sent it in full (server side).

=cut

sub _argument ($message) {
  OpenAPI::Humbug::Error->throw(kind => 'argument', code => 'client.argument', message => $message);
}

sub request ($class, $req) {
  _argument('request must be a Mojo::Message::Request')
    unless blessed $req && $req->isa('Mojo::Message::Request');

  my %request = (
    method => $req->method,
    url    => _url($req),
    _headers($req),
  );

  # A request without Content-Length or Transfer-Encoding has no body (RFC 9112 6.3)
  my $body = _body('request', $req);
  my $headers = $req->headers;
  $request{body} = $body
    if length $body || defined $headers->content_length || defined $headers->transfer_encoding;

  return \%request;
}

sub response ($class, $res, $method = undef) {
  _argument('response must be a Mojo::Message::Response')
    unless blessed $res && $res->isa('Mojo::Message::Response');

  my $status = $res->code;
  _argument('response has no status code; it has not been received or generated yet')
    unless defined $status;

  my %response = (
    status => $status,
    _headers($res),
  );

  # Responses to HEAD, and 1xx, 204 and 304 responses, have no body; any other response has one,
  # possibly empty, even without Content-Length (it then ends with the connection; RFC 9112 6.3)
  my $body = _body('response', $res);
  my $bodiless = $status =~ /^1/ || $status == 204 || $status == 304
    || (defined $method && uc $method eq 'HEAD');
  $response{body} = $body if length $body || !$bodiless;

  return \%response;
}

sub transaction ($class, $tx) {
  _argument('transaction must be a Mojo::Transaction::HTTP')
    unless blessed $tx && $tx->isa('Mojo::Transaction::HTTP');

  my $req = $tx->req;
  my %args = (request => $class->request($req));
  $args{response} = $class->response($tx->res, $req->method) if $class->response_complete($tx->res);
  return %args;
}

sub response_complete ($class, $res) {
  return defined $res->code && $res->is_finished;
}

# the effective absolute URL, without a fragment
sub _url ($req) {
  # to_abs returns a copy, resolved against the base Mojo sets from Host and the connection
  my $url = $req->url->to_abs;
  _argument('request URL is relative and Mojo has no scheme and host to resolve it against')
    unless $url->is_abs && length($url->host // '');
  $url->fragment(undef);
  return $url->to_string;
}

sub _headers ($msg) {
  my $headers = $msg->headers;
  my @lines;
  for my $name ($headers->names->@*) {
    push @lines, [$name, $_] for $headers->every_header($name)->@*;
  }
  return (headers => \@lines);
}

sub _body ($side, $msg) {
  my $content = $msg->content;
  _argument("$side is still being received") if $content->is_parsing_body;
  _argument("$side body is streamed (dynamic content), so its bytes are not available") if $content->is_dynamic;
  _argument("$side body is multipart; Mojo keeps it only as parsed parts, so its original bytes are not available")
    if $content->is_multipart;
  return $content->asset->slurp;
}
