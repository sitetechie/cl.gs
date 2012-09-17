package clgs;

use strict;
use warnings;
use 5.010;
use Dancer ':syntax';
use Dancer::Plugin::Redis;
use JSON ();
use Digest::MD5 qw(md5_hex);
use List::Util qw/first/;
use URI;
use Data::Validate::URI qw(is_web_uri);
use clgs::Redis;
use Data::Dumper;

our $VERSION = '0.001';

hook before => sub {
    var store => clgs::Redis->new(
        connection => redis,
        base       => request->base()->as_string()
    );
    redis->ping();
    
    # check and/or set the cookie
    var cookiename => config->{'cl.gs'}{cookie_name} || '__clgsAA';
    
    my $reset_cookie = 0;
    my $expires = config->{'cl.gs'}{cookie_expires};
    if(!$expires) {
        $expires = (time + 86400 * 90); # 90 days
    }
    elsif($expires =~ /^\d+$/) {
        $expires = (time + $expires);
        # always set the cookie on relative expiration
        $reset_cookie++;
    }
    
    my $cn = vars->{cookiename};
    if(!cookies->{$cn} || $reset_cookie) {
        my @host = split(':',request->host());
        set_cookie $cn => (cookies->{$cn} && cookies->{$cn}->value()) || 
                        _gen_visitor_id(request->user_agent),
                   expires =>  $expires,
                   domain => '.' . $host[0];
    }
 };

# in case of non-rooted app, set uri_base (for js and css)
hook 'before_template_render' => sub {
    my $tokens = shift;
    if(request->base->path ne '/') {
        $tokens->{uri_base} = request->base->path;
    }
};

sub _gen_visitor_id {
    my $user_agent = shift;
    
    my $message = $user_agent . int(rand(0x7fffffff));
    my $md5_string = md5_hex($message);
    return "0x" . substr($md5_string, 0, 16);
 }


#--- ROUTES --------------------------------------------------------------------

get '/' => sub {
    template 'index';
};

#-- create shortcode

post '/' => sub {
    return send_error("Bad Request", 400) unless params->{url};

    # find owner cookie or generate some random id if cookies disabled
    my $cn = vars->{cookiename};
    my $owner = (cookies->{$cn} && cookies->{$cn}->value()) 
        || _gen_visitor_id();
    
    # only HTTP or HTTPS URLs are accepted (including IP addresses)
    my $error = { error => 'Invalid URL' };
    my $url = is_web_uri(params->{url}) or return request->is_ajax() ? 
            JSON->new->encode($error) : template 'index', $error;

    my $code = vars->{store}->add_url($url, $owner);

    my $response = {
        url       => $url,
        code      => $code,
        short_url => vars->{store}->base . $code,
        stats_url => vars->{store}->base . "$code\+",
        };    
    
    return request->is_ajax() ? 
        JSON->new->encode($response) : template 'results.tt', $response;
};

#-- stats

get qr{^\/(?<code>[A-Za-z0-9]+)\+$} => sub {
    my $code = captures->{'code'};

    my $long = vars->{store}->get_url($code) 
        or return send_error("Not Found", 404);
    
    my $stats = { 
        code     => $code,
        url      => $long,
        stats    => [vars->{store}->get_stats($code)],
    };
    
    template 'stats', $stats;
};


#-- redirect shortcode

get qr{^\/(?<code>[A-Za-z0-9]+)$} => sub {
    my $code = captures->{'code'};

    my $redirection = vars->{store}->get_url($code) 
        or return send_error("Not Found", 404);
    
    my $entry = {
        remote_address => request->remote_address,
        referer        => request->referer,
        user_agent     => request->user_agent,
        language       => request->header('Accept-Language'),
        target         => $redirection,
        visitor_id     => cookies->{ vars->{cookiename} }->value(),
        #datetime      => DateTime->now()->datetime()
    };        
    vars->{store}->add_visit($code, $entry);

    return defined(params->{debug}) ? 
        "REDIR TO $redirection <pre>" . Dumper($entry) . '</pre>' :
        redirect $redirection, 307;
};

1;
__END__

=pod

=head1 NAME

cl.gs - Redis-based URL Shortener

=head1 VERSION

0.001

=for :stopwords cpan testmatrix url annocpan anno bugtracker rt cpants kwalitee diff irc mailto metadata placeholders

=head1 SYNOPSIS

    use Dancer;
    use clgs;
    dance;

=head1 DESCRIPTION

cl.gs is a small URL Shortener built on top of Redis and the L<Dancer> framework.

A word of caution: don't use this for anything other than a private installation
for personal use. Any publicly accessible URL shortener should take proper 
security and anti-spam measures to prevent shortlinking to malware sites,
such as bot blocking captcha's, blacklist checks, rate limiting, webcrawler 
policies, short url decoding capabilities, etc.

=head2 Routes

=over 4

=item GET /

Show form to encode a long url.

=item POST /

Encode a long url and show the results.

=item GET /:short_code

Redirect to the long url for this short code.

=item GET /:short_code+

Show traffic statistics for this short code.

=back

=head1 CONFIGURATION

Configuration can be achieved via a config.yml file or via the set keyword.
To use the config.yml approach, you will need to install L<YAML>.
See the L<Dancer> documentation for more information.

The configurable settings are:

=over 4

=item * cookie_name

Name of the client cookie. Defaults to '__clgs'.

=item * cookie_expires

Either a date (absolute expiration) or number of seconds (relative expiration)

Example:

  clgs:
    cookie_expires: Thu, 01-Jan-1970 01:00:00 GMT

Defaults to relative 90 days.

#Just comment this setting out to expire cookies at the end of the session (not
#recommended).

=back

Example config.yml:

    # Dancer specific config settings
    logger: file
    log: errors

    clgs:
        cookie_name: c3RhbXBzMQ
        cookie_expires: 3600

You can alternatively configure the server via the 'set' keyword in the source
code. This approach does not require a config file.

    use Dancer;
    use clgs;

    # Dancer specific config settings
    set logger      => 'file';
    set log         => 'debug';
    set show_errors => 1;

    set clgs => {
        cookie_name => 'c3RhbXBzMQ',
    };

    dance;

=head1 DEPLOYMENT

Deployment is very flexible. It can be run on a web server via CGI or FastCGI.
It can also be run on any L<Plack> web server. See L<Dancer::Deployment> for 
more details.

=head2 FastCGI

cl.gs can be run via FastCGI. This requires that you have the L<FCGI> and 
L<Plack> modules installed. Here is an example FastCGI script.
It assumes your cl.gs server is in the file F<clgs.pl>.

    #!/usr/bin/env perl
    use Dancer ':syntax';
    use Plack::Handler::FCGI;

    my $app = do "/path/to/clgs.pl";
    my $server = Plack::Handler::FCGI->new(nproc => 5, detach => 1);
    $server->run($app);

Here is an example lighttpd config. It assumes you named the above file clgs.fcgi.

    fastcgi.server += (
        "/" => ((
            "socket" => "/tmp/fcgi.sock",
            "check-local" => "disable",
            "bin-path" => "/path/to/clgs.fcgi",
        )),
    )

Now cl.gs will be running via FastCGI under /.

=head2 Plack

cl.gs can be run with any L<Plack> web server.  Just run:

    plackup clgs.pl

You can change the Plack web server via the -s option to plackup.

=head1 CONTRIBUTING

This module is developed on Github at:

L<https://github.com/sitetechie/cl.gs>

Feel free to fork the repo and submit pull requests!
  
  git clone https://github.com/sitetechie/cl.gs

=head1 SUPPORT

=head2 Perldoc

You can find documentation for this module with the perldoc command.

  perldoc clgs

=head2 Website

L<http://cl.gs>

=head2 Email

You can email the author of this module at C<SITETECH at cpan.org> asking for 
help with any problems you have.

=head1 AUTHOR

Peter de Vos <techie@sitetechie.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2012 by Site Corporation.

This module is free software; you can redistribute it and/or modify it under the
same terms as Perl itself. See L<perlartistic>.

=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT
WHEN OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER
PARTIES PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND,
EITHER EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE. THE ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE
SOFTWARE IS WITH YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME
THE COST OF ALL NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE LIABLE
TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE THE
SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH
DAMAGES.

=cut