# Copyright (c) 1998-2004 Graham Barr <gbarr@pobox.com>. All rights reserved.
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

package LWP::Protocol::ldap;

use Carp ();

use HTTP::Status qw(HTTP_OK HTTP_BAD_REQUEST HTTP_INTERNAL_SERVER_ERROR HTTP_NOT_IMPLEMENTED);
use HTTP::Negotiate ();
use HTTP::Response ();
use LWP::MediaTypes ();
require LWP::Protocol;
@ISA = qw(LWP::Protocol);

$VERSION = "1.18";

use strict;
eval {
  require Net::LDAP;
};
my $init_failed = $@ ? $@ : undef;

sub request {
  my($self, $request, $proxy, $arg, $size, $timeout) = @_;

  $size = 4096 unless $size;

  LWP::Debug::trace('()') if defined &LWP::Debug::trace;

  # check proxy
  if (defined $proxy) {
    return HTTP::Response->new(HTTP_BAD_REQUEST,
                              'You can not proxy through the ldap');
  }

  my $url = $request->url;
  my $scheme   = $url->scheme;
  my $userinfo = $url->can('userinfo') ? $url->userinfo : '';
  my $dn       = $url->dn;
  my @attrs    = $url->attributes;
  my $scope    = $url->scope || 'base';
  my $filter   = $url->filter;

  # check scheme
  if ($scheme !~ /^ldap[si]?$/) {
    return HTTP::Response->new(HTTP_INTERNAL_SERVER_ERROR,
                               "LWP::Protocol::ldap::request called for '$scheme'");
  }

  # check method
  my $method = $request->method;

  unless ($method =~ /^(?:GET|HEAD)$/) {
    return HTTP::Response->new(HTTP_NOT_IMPLEMENTED,
                               "Library does not allow method $method for '$scheme:' URLs");
  }

  if ($init_failed) {
    return HTTP::Response->new(HTTP_INTERNAL_SERVER_ERROR,
                               $init_failed);
  }

  my ($user, $password) = defined($userinfo) ? split(":", $userinfo, 2) : ();
  my %extn     = $url->extensions;
  my $tls     = exists($extn{'x-tls'}) ? 1 : 0;
  my $format = lc($extn{'x-format'} || 'html');

  # analyse HTTP headers
  if (my $accept = $request->header('Accept')) {
    $format = 'ldif' if $accept =~ m!\btext/(x-)?ldif\b!;
    $format = 'json' if $accept =~ m!\b(?:text|application)/json\b!;
  }

  if (!$user) {
    if (my $authorization = $request->header('Authorization')) {
      # we only accept Basic authorization for now
      if ($authorization =~ /^Basic\s+([A-Z0-9+\/=]+)$/i) {
        require MIME::Base64;
        ($user, $password) = split(":", MIME::Base64::decode_base64($1), 2);
      }
    }
  }

  # connect to LDAP server
  my $ldap = new Net::LDAP($url->as_string);
  if (!$ldap) {
    my $res = HTTP::Response->new(HTTP_BAD_REQUEST,
                                  "Connection to LDAP server failed");
    $res->content_type("text/plain");
    $res->content($@);
    return $res;
  }

  # optional: startTLS
  if ($tls && $scheme ne 'ldaps') {
    my $mesg = $ldap->start_tls();
    if ($mesg->code) {
      my $res = HTTP::Response->new(HTTP_BAD_REQUEST,
                                    "LDAP return code " . $mesg->code);
      $res->content_type("text/plain");
      $res->content($mesg->error);
      return $res;
    }
  }

  # optional: simple bind
  if ($user) {
    my $mesg = $ldap->bind($user, password => $password);

    if ($mesg->code) {
      my $res = HTTP::Response->new(HTTP_BAD_REQUEST,
                                    "LDAP return code " . $mesg->code);
      $res->content_type("text/plain");
      $res->content($mesg->error);
      return $res;
    }
  }

  # do the search
  my %opts = ( scope => $scope );
  $opts{base}   = $dn      if $dn;
  $opts{filter} = $filter  if $filter;
  $opts{attrs}  = \@attrs  if @attrs;

  my $mesg = $ldap->search(%opts);
  if ($mesg->code) {
    my $res = HTTP::Response->new(HTTP_BAD_REQUEST,
                                  "LDAP return code " . $mesg->code);
    $res->content_type("text/plain");
    $res->content($mesg->error);
    return $res;
  }

  # Create an initial response object
  my $response = HTTP::Response->new(HTTP_OK, "Document follows");
  $response->request($request);

  # return data in the format requested
  if ($format eq 'ldif') {
    require Net::LDAP::LDIF;

    open(my $fh, ">", \my $content);
    my $ldif = Net::LDAP::LDIF->new($fh, "w", version => 1);

    while(my $entry = $mesg->shift_entry) {
      $ldif->write_entry($entry);
    }
    $ldif->done;
    close($fh);
    $response->header('Content-Type' => 'text/ldif');
    $response->header('Content-Length', length($content));
    $response = $self->collect_once($arg, $response, $content)
      if ($method ne 'HEAD');
  }
  elsif ($format eq 'json') {
    require JSON;

    my $entry;
    my $index;
    my %objects;

    for ($index = 0 ; $entry = $mesg->entry($index); $index++) {
      my $dn = $entry->dn;
      
      $objects{$dn} = {};
      foreach my $attr (sort($entry->attributes)) {
        $objects{$dn}{$attr} = $entry->get_value($attr, asref => 1);
      }
    }

    my $content = JSON::to_json(\%objects, {pretty => 1, utf8 => 1});
    $response->header('Content-Type' => 'text/json; charset=utf-8');
    $response->header('Content-Length', length($content));
    $response = $self->collect_once($arg, $response, $content)
	if ($method ne 'HEAD');
  }
  else {
    my $content = "<head><title>Directory Search Results</title></head>\n<body>";
    my $entry;
    my $index;

    for ($index = 0 ; $entry = $mesg->entry($index); $index++) {
      my $attr;

      $content .= $index ? qq{<tr><th colspan="2"><hr>&nbsp</tr>\n} : "<table>";

      $content .= qq{<tr><th colspan="2">} . $entry->dn . "</th></tr>\n";

      foreach $attr ($entry->attributes) {
        my $vals = $entry->get_value($attr, asref => 1);
        my $val;

        $content .= q{<tr><td align="right" valign="top"};
        $content .= q{ rowspan="} . scalar(@$vals) . q{"}
          if (@$vals > 1);
        $content .= ">" . $attr  . "&nbsp</td>\n";

        my $j = 0;
        foreach $val (@$vals) {
	  $val = qq!<a href="$val">$val</a>! if $val =~ /^https?:/;
	  $val = qq!<a href="mailto:$val">$val</a>! if $val =~ /^[-\w]+\@[-.\w]+$/;
          $content .= "<tr>" if $j++;
          $content .= "<td>" . $val . "</td></tr>\n";
        }
      }
    }

    $content .= "</table>" if $index;
    $content .= "<hr>";
    $content .= $index ? sprintf("%s Match%s found",$index, $index>1 ? "es" : "")
		       : "<b>No Matches found</b>";
    $content .= "</body>\n";
    $response->header('Content-Type' => 'text/html');
    $response->header('Content-Length', length($content));
    $response = $self->collect_once($arg, $response, $content)
      if ($method ne 'HEAD');
  }

  $ldap->unbind;

  $response;
}

1;
