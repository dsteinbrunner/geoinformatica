#!/usr/bin/perl

use strict;
use Carp;
use Encode;
use DBI;
use CGI;
use Geo::Proj4;
use Gtk2::Ex::Geo;
use Geo::Raster;
use Geo::Vector;
use JSON;

my $config;
{
    open(my $fh, '<', "wms.conf") or die $!;
    my @json = <$fh>;
    close $fh;
    $config = decode_json "@json";
}
my $q = CGI->new;
my %names = ();

eval {
    page($q);
};
if ($@) {
    #print STDERR "WMS error: $@\n";
    print $q->header($config->{MIME});
    print('<?xml version="1.0" encoding="UTF-8"?>',"\n");
    my($error) = ($@ =~ /(.*?)\.\#/);
    $error =~ s/ $//;
    $error = { code => $error } if $error eq 'LayerNotDefined';
    $error = 'Unspecified error' unless $error;
    xml_element('ServiceExceptionReport',['ServiceException', $error]);
}

sub page {
    my($q) = @_;
    for ($q->param) {
	croak "Parameter ".uc($_)." given more than once.#" if exists $names{uc($_)};
	$names{uc($_)} = $_;
    }
    $q->{resource} = $config->{resource};
    my $request = $q->param($names{REQUEST});
    my $version = $q->param($names{WMTVER});
    $version = $q->param($names{VERSION}) if $q->param($names{VERSION});
    $version = '1.1.1' unless $version;
    croak "Not a supported WMS version.#" unless $version eq $config->{version};
    my $service = $q->param($names{SERVICE});
    $service = 'WMS'unless $service;
    if ($request eq 'GetCapabilities' or $request eq 'capabilities') {
	GetCapabilities($q, $version);
    } elsif ($request eq 'GetMap') {
	GetMap($q, $version);
    } elsif ($request eq 'GetFeatureInfo') {
	GetFeatureInfo($q, $version);
    } else {
	print 
	    $q->header(), 
	    $q->start_html, 
	    $q->a({-href=>$q->{resource}.'REQUEST=GetCapabilities'}, "GetCapabilities"), 
	    $q->end_html;
    }
}

sub GetCapabilities {
    my($q, $version) = @_;
    print($q->header( -type => $config->{MIME} ));
    print('<?xml version="1.0" encoding="UTF-8"?>',"\n");
    print("<!DOCTYPE WMT_MS_Capabilities SYSTEM \"http://schemas.opengeospatial.net/wms/1.1.1/capabilities_1_1_1.dtd\"\n");
    print(" [\n");
    print(" <!ELEMENT VendorSpecificCapabilities EMPTY>\n");
    print(" ]>\n\n");

    xml_element('WMT_MS_Capabilities', { version=>$version }, '<>');
    Service($q, $version);
    Capability($q, $version);
    xml_element('/WMT_MS_Capabilities', '<>');
}

sub GetMap {
    my($q, $version) = @_;

    my @layers = split(/,/, $q->param($names{LAYERS}));
    my $epsg = $1 if $q->param($names{SRS}) =~ /EPSG:(\d+)/;
    my @bbox = split(/,/, $q->param($names{BBOX}));
    my($w) = $q->param($names{WIDTH}) =~ /(\d+)/;
    my($h) = $q->param($names{HEIGHT}) =~ /(\d+)/;
    my $format = $q->param($names{FORMAT});
    my $transparent = $q->param($names{TRANSPARENT}) eq 'TRUE';
    my @bgcolor = $q->param($names{BGCOLOR}) =~ /^0x(\w\w)(\w\w)(\w\w)/;
    $_ = hex($_) for (@bgcolor);
    push @bgcolor, $transparent ? 0 : 255;
    my $time = $q->param($names{TIME});

    $w = 512 unless $w;
    $h = 512 unless $h;

    # jotain rajaa:
    $w = $config->{max_width} if $w > $config->{max_width};
    $h = $config->{max_height} if $h > $config->{max_height};

    my $pixel_size = ($bbox[2] - $bbox[0])/$w; # assuming square pixels
    my ($minX, $minY, $maxX, $maxY) = @bbox;
    @bbox = ($minX, $minY, $minX+$w*$pixel_size, $minY+$h*$pixel_size);

    my @stack = ();
    for my $layer (@layers) {
	my $l = layer($layer, $epsg, $time, $pixel_size);
	push @stack, $l if $l;
    }
    croak "LayerNotDefined .#" unless @stack;

    #print STDERR "create: @stack ".($minX)." ".($minY+$h*$pixel_size)." $w $h (@bgcolor)\n";

    my $pixbuf = Gtk2::Ex::Geo::Canvas->new(
	[@stack], $minX, $minY+$h*$pixel_size, $pixel_size, 0, 0, $w, $h, @bgcolor );

    #print STDERR "no pixbuf from @stack\n", return unless $pixbuf;

    my $buffer = $pixbuf->save_to_buffer($format eq 'image/png' ? 'png' : 'jpeg');
    print "Content-type: $format\n";
    print "Content-length: ",length($buffer),"\n\n";
    print $buffer;

}

sub GetFeatureInfo {
    my($q, $version) = @_;
    my @layers = split(/,/, $q->param($names{LAYERS}));
    my $epsg = $1 if $q->param($names{SRS}) =~ /EPSG:(\d+)/;
    my @bbox = split(/,/, $q->param($names{BBOX}));
    my($w) = $q->param($names{WIDTH}) =~ /(\d+)/;
    my($h) = $q->param($names{HEIGHT}) =~ /(\d+)/;
    my $format = $q->param($names{FORMAT});
    my $transparent = $q->param($names{TRANSPARENT});

    my $polygon = $q->param($names{POLYGON});

    my($X) = $q->param($names{X}) =~ /(\d+)/;
    my($Y) = $q->param($names{Y}) =~ /(\d+)/;
    my ($minX, $minY, $maxX, $maxY) = @bbox;
    my $pixel_size = ($maxX - $minX)/$w; # assuming square pixels
    my $x = $minX + $pixel_size * $X;
    my $y = $maxY - $pixel_size * $Y;

    my $wkt = $polygon ? $polygon : "POINT($x $y)";
    my $within = $polygon ? 
	"within(the_geom, st_transform(st_geomfromewkt('SRID=3035;$wkt'),2393))" :
	"within(st_transform(st_geomfromewkt('SRID=3035;$wkt'),2393), the_geom)";
    my $sql = "select computed from \"1km\" where $within";

    my $dbh = DBI->connect('dbi:Pg:dbname=OILRISK', 'postgres', 'lahti') or croak $DBI::errstr;
    my $sth = $dbh->prepare($sql) or croak $dbh->errstr;
    $sth->execute() or croak $dbh->errstr;
    my @report;
    while ( my @row = $sth->fetchrow_array ) {
	push @report, $row[0];
    }

    print 
	$q->header(),
	'<meta content="text/html;charset=UTF-8" http-equiv="Content-Type">',
	$q->start_html,
	decode('utf8', "Infoa: valitussa kohdassa ($x,$y) val on:<br/>".join('<br/>',@report)), 
	$q->end_html;
}

sub layer {
    my($layer, $epsg, $time, $pixel_scale) = @_;
    #print STDERR "create layer $layer $epsg\n";
    my @layers = @{$config->{Layer}->{Layers}};
    for my $l (@layers) {
	next unless $layer eq $l->{Name};
	#print STDERR "creating layer $l->{Name}\n";
	if ($l->{Filename}) {
	    my $r = Geo::Raster::Layer->new(filename => $l->{Filename});
	    $r->band()->SetNoDataValue($l->{NoDataValue}) if exists $l->{NoDataValue};
	    #print STDERR "created layer $r\n";
	    return $r;
	}
	if ($l->{Datasource}) {
	    my %param = (datasource => $l->{Datasource});
	    if (exists $l->{SQL}) {
		$l->{SQL} =~ s/\$time/$time/;
		$l->{SQL} =~ s/\$pixel_scale/$pixel_scale/g;
		if ($epsg != $l->{EPSG}) {
		    $l->{SQL} =~ s/the_geom/st_transform(the_geom,$epsg)/;
		}
		$param{SQL} = $l->{SQL};
		#print STDERR "SQL: $param{SQL}\n";
	    }
	    $param{single_color} = 
		[$l->{single_color}->{R},$l->{single_color}->{G},$l->{single_color}->{B},$l->{single_color}->{A}]
		if exists $l->{single_color};
	    for (qw/encoding/) {
		$param{$_} = $l->{$_} if exists $l->{$_};
	    }
	    my $v = Geo::Vector::Layer->new(%param);
	    #print STDERR "created layer $v ".$v->feature_count()."\n";
	    for (sort keys %$v) {
		#print STDERR "$_ -> $v->{$_}\n";
	    }
	    for (qw/SYMBOL_SIZE LABEL_FIELD INCREMENTAL_LABELS/) {
		$v->{$_} = $l->{$_} if exists $l->{$_};
	    }
	    return $v;
	}
    }
    0;
}

sub Service {
    my($q, $version) = @_;
    xml_element('Service', '<>');
    xml_element('Name', 'OGC:WMS');
    xml_element('Title', $config->{Title});
    xml_element('Abstract', $config->{Abstract});
    xml_element('OnlineResource', { 'xmlns:xlink' => 'http://www.w3.org/1999/xlink', 
				    'xlink:type' => 'simple', 
				    'xlink:href' => $q->{resource}});
    xml_element('/Service', '<>');
}

sub Capability {
    my($q, $version) = @_;
    xml_element('Capability', '<>');
    Request($q, $version);
    Exception($q, $version);
    xml_element('VendorSpecificCapabilities');
    Layers($q, $version);
    xml_element('/Capability', '<>');
}

sub Request {
    my($q, $version) = @_;
    xml_element('Request', '<>');
    my %request = ( GetCapabilities => 'application/vnd.ogc.wms_xml',
		    GetMap => ['image/png', 'image/jpeg'],
		    GetFeatureInfo => 'text/html' );
    for my $key ('GetCapabilities', 'GetMap', 'GetFeatureInfo') {
	my @format;
	if (ref $request{$key}) {
	    for my $f (@{$request{$key}}) {
		push @format, [ 'Format', $f ];
	    }
	} else {
	    @format = ([ 'Format', $request{$key} ]);
	}	
	xml_element( $key, [
			    @format,
			    [ 'DCPType', [ [ 'HTTP', [ [ 'Get', [ [ 'OnlineResource',
								    { 'xmlns:xlink' => 'http://www.w3.org/1999/xlink',
								      'xlink:type' => 'simple',
								      'xlink:href' => $q->{resource} } ]]]]]]]] );
    }
    xml_element('/Request', '<>');
}

sub Exception {
    my($q, $version) = @_;
    xml_element('Exception', [ 'Format', 'application/vnd.ogc.se_xml' ] );
}

sub Layers {
    my($q, $version) = @_;
    
    my ($minX, $minY, $maxX, $maxY) = ($config->{minX}, $config->{minY}, $config->{maxX}, $config->{maxY});
    my $epsg = $config->{Layer}->{EPSG};
    my @epsg = split /,/, $epsg;
    $epsg = $epsg[0];
    #print STDERR "epsg=@epsg $epsg\n";
    shift @epsg;
    my $proj = Geo::Proj4->new(init => "epsg:$epsg");
    my ($min_lat,$min_lon) = $proj->inverse($minX, $minY);
    my ($max_lat,$max_lon) = $proj->inverse($maxX, $maxY);
    
    Layer($q, $version, 
	  Name => $config->{Layer}->{Name},
	  Title => $config->{Layer}->{Title},
	  SRS => "EPSG:$epsg",
	  EPSG => \@epsg,
	  LatLonBoundingBox => { minx => $min_lon, miny=> $min_lat, maxx => $max_lon, maxy => $max_lat },
	  BoundingBox => { SRS => "EPSG:$epsg", minx => $minX, miny=> $minY, maxx => $maxX, maxy => $maxY },
	  Layers => $config->{Layer}->{Layers}
	);
}

sub Layer {
    my($q, $version, %def) = @_;
    xml_element('Layer', '<>');
    xml_elements( ['Name', $def{Name}], 
		  ['Title', $def{Title}],
		  ['SRS', $def{SRS}],
		  ['LatLonBoundingBox', $def{LatLonBoundingBox}],
		  ['BoundingBox', $def{BoundingBox}] );
    for my $epsg  (@{$def{EPSG}}) {
	xml_element('SRS', "EPSG:$epsg");
    }
    for my $simple (@{$def{Layers}}) {
	xml_element('Layer', [
			['Name', $simple->{Name}],
			['Title', $simple->{Title}],
			['Abstract', $simple->{Abstract}]]);
    }
    xml_element('/Layer', '<>');
}

sub serve_document {
    my($q, $doc, $mime_type) = @_;
    my $length = (stat($doc))[10];
    print "Content-type: $mime_type\n";
    print "Content-length: $length\n\n";
    open(DOC, '<', $doc) or croak "Couldn't open $doc: $!";
    my $data;
    while( sysread(DOC, $data, 10240) ) {
	print $data;
    }
    close DOC;
}

sub xml_elements {
    for my $e (@_) {
	if (ref($e) eq 'ARRAY') {
	    xml_element(@$e);
	} else {
	    xml_element($e->{element}, $e->{attributes}, $e->{content});
	}
    }
}

sub xml_element {
    my $element = shift;
    my $attributes;
    my $content;
    for my $x (@_) {
	$attributes = $x, next if ref($x) eq 'HASH';
	$content = $x;
    }
    print("<$element");
    if ($attributes) {
	for my $a (keys %$attributes) {
	    print(" $a=\"$attributes->{$a}\"");
	}
    }
    unless ($content) {
	print("/>\n");
    } else {
	if (ref $content) {
	    print(">");
	    if (ref $content->[0]) {
		for my $e (@$content) {
		    xml_element(@$e);
		}
	    } else {
		xml_element(@$content);
	    }
	    print("</$element>\n");
	} elsif ($content eq '<>') {
	    print(">\n");
	} elsif ($content) {
	    print(">$content</$element>\n");	
	}
    }
}