#!/usr/bin/perl -w

use utf8;
use strict;
use IO::Handle;
use Carp;
use Encode;
use DBI;
use CGI;
use XML::Simple;
use Data::Dumper;

use Geo::GDAL;
#use Geo::Proj4;
#use Gtk2::Ex::Geo;
#use Geo::Raster;
#use Geo::Vector;
use JSON;
use lib '.';
require WXS;
WXS->import(':all');

binmode STDERR, ":utf8";
binmode STDOUT, ":utf8";
my $config;
my $q = CGI->new;
my $header = 0;
my %names = ();

eval {
    $config = WXS::config();
    page();
};
error(cgi => $q, header => $header, msg => $@, type => $config->{MIME}) if $@;

sub page {
    for ($q->param) {
	croak "Parameter ".uc($_)." given more than once.#" if exists $names{uc($_)};
	$names{uc($_)} = $_;
    }

    my $request;
    my $version;
    my $service;
    my $bbox;
    my $typename;

    if ($names{POSTDATA}) {
	my $post = XMLin('<xml>'.$q->param($names{POSTDATA}).'</xml>');
	remove_ns($post);

	#print STDERR Dumper($post);

	for my $k (keys %$post) {
	    if ($k eq 'wfs:GetFeature') {
		my $h = $post->{$k};
		$service = $h->{'service'};
		$version = $h->{'version'};
		$request = 'GetFeature';
		next unless $h->{'wfs:Query'};
		$h = $h->{'wfs:Query'};
		$typename = $h->{typeName};
		$typename =~ s/^feature://;
		next unless $h->{'ogc:Filter'};
		$h = $h->{'ogc:Filter'};
		next unless $h->{'ogc:BBOX'};
		$h = $h->{'ogc:BBOX'};
		$bbox = $h->{'gml:Box'}{'gml:coordinates'}{content};
		$bbox =~ s/ /,/;
	    } elsif ($k eq 'x') {
	    }
	}

	print STDERR "$request; $version; $service; $bbox; $typename\n";

    } else {

	$q->{resource} = $config->{resource};
	$request = $q->param($names{REQUEST}) || 'capabilities';
	$version = $q->param($names{WMTVER});
	$version = $q->param($names{VERSION}) if $q->param($names{VERSION});
	$version = '1.1.0' unless $version;
	#croak "Not a supported WFS version.#" unless $version eq $config->{version};
	$service = $q->param($names{SERVICE});
	$service = 'WFS'unless $service;
	$bbox = $q->param($names{BBOX});
	$typename = decode utf8=>$q->param($names{TYPENAME});

    }


    if ($request eq 'GetCapabilities' or $request eq 'capabilities') {
	GetCapabilities($version);
    } elsif ($request eq 'DescribeFeatureType') {
	DescribeFeatureType($version, $typename);
    } elsif ($request eq 'GetFeature') {
	GetFeature($version, $typename, $bbox);
    } else {
	croak('Unrecognized request: '.$request);
    }
}

sub GetFeature {
    my($version, $typename, $bbox) = @_;
    my $type = feature($typename);
    croak "No such feature type: $typename" unless $type;

    my $maxfeatures = $q->param($names{MAXFEATURES});
    ($maxfeatures) = $maxfeatures =~ /(\d+)/ if defined $maxfeatures;
    
    # feed the copy directly to stdout
    print($q->header(-type => $config->{MIME}, -charset=>'utf-8'));
    STDOUT->flush;
    my $vsi = '/vsistdout/';
    my $gml = Geo::OGR::Driver('GML')->Create($vsi);

    my $datasource = Geo::OGR::Open($type->{Datasource});
    my $layer;
    if ($type->{Layer}) {
	$layer = $datasource->Layer($type->{Layer});
    } elsif ($type->{Table}) {	    
	my @cols;
	for my $f (keys %{$type->{Schema}}) {
	    next if $f eq 'ID';
	    my $n = $f;
	    $n =~ s/ /_/g;
	    # need to use specified GeometryColumn and only it
	    next if $type->{Schema}{$f} eq 'geometry' and not ($f eq $type->{GeometryColumn});
	    push @cols, "\"$f\" as \"$n\"";
	}
	#my $sql = "select ".join(',',@cols)." from \"$type->{Table}\"";

# todo: a join between two tables, howto configure?      
	my $sql;

# select "Lajin nimi" from "Lajiesiintymät","Lajit" where
# "Lajiesiintymät"."Lajin nimi"="Lajit"."Nimi"
#

	if ($type->{Table} eq 'Lajiesiintymät') {
	    for (@cols) {
		$_ = "\"$type->{Table}\".".$_;
	    }
	    push @cols,"\"Lajit\".\"IUCN 2010\" as \"IUCN_2010\"";
	    my @tables = ("\"$type->{Table}\"",'"Lajit"');
	    $sql = "select ".join(',',@cols)." from ".join(',',@tables)." where ST_IsValid($type->{GeometryColumn})";
	    $sql .= " and \"$type->{Table}\".\"Lajin nimi\"=\"Lajit\".\"Nimi\"";
	    #print STDERR "$sql\n";
	} else {
	    $sql = "select ".join(',',@cols)." from \"$type->{Table}\" where ST_IsValid($type->{GeometryColumn})";
	}

	$layer = $datasource->ExecuteSQL($sql);
    } else {
	croak "missing information in configuration file";
    }

    if ($bbox) {
	my @bbox = split /,/, $bbox;
	$layer->SetSpatialFilterRect(@bbox);
    }    

    #$gml->CopyLayer($layer, $type->{Title});

    my $l2 = $gml->CreateLayer($type->{Title});
    my $d = $layer->GetLayerDefn;
    for (0..$d->GetFieldCount-1) {
	my $f = $d->GetFieldDefn($_);
	$l2->CreateField($f);
    }
    my $i = 0;
    $layer->ResetReading;
    while (my $f = $layer->GetNextFeature) {
	$l2->CreateFeature($f);
	$i++;
	last if defined $maxfeatures and $i >= $maxfeatures;
    }

}

sub DescribeFeatureType {
    my($version, $typename) = @_;

    my @typenames = split(/\s*,\s*/, $typename);
    for my $name (@typenames) {
	my $type = feature($name);
	croak "No such feature type: $typename" unless $type;
    }

    my($out, $var);
    open($out,'>', \$var);
    select $out;
    print('<?xml version="1.0" encoding="UTF-8"?>',"\n");
    xml_element('schema', 
		{ version => '0.1',
		  targetNamespace => "http://mapserver.gis.umn.edu/mapserver",
		  xmlns => "http://www.w3.org/2001/XMLSchema",
		  'xmlns:ogr' => "http://ogr.maptools.org/",
		  'xmlns:ogc' => "http://www.opengis.net/ogc",
		  'xmlns:xsd' => "http://www.w3.org/2001/XMLSchema",
		  'xmlns:gml' => "http://www.opengis.net/gml",
		  elementFormDefault => "qualified" }, 
		'<');
    xml_element('import', { namespace => "http://www.opengis.net/gml",
			    schemaLocation => "http://schemas.opengis.net/gml/2.1.2/feature.xsd" } );

    for my $name (@typenames) {
	my $type = feature($name);
	my @elements;
	if ($type->{Schema}) {
	    for my $col (keys %{$type->{Schema}}) {
		if ($type->{Schema}{$col} eq 'geometry' and not($typename =~ /$col$/)) {
		    next;
		}
		my $t = $type->{Schema}{$col};
		$t = "gml:GeometryPropertyType" if $t eq 'geometry';
		my $c = $col;
		$c =~ s/ /_/g; # field name adjustments as GDAL does them
		$c =~ s/ä/a/g; # extra name adjustments, needed by QGIS
		push @elements, ['element', { name => $c,
					      type => $t,
					      minOccurs => "0",
					      maxOccurs => "1" } ];
	    }
	    # todo: add a column from another table through join (see above in GetFeature)
	    if ($type->{Table} eq 'Lajiesiintymät') {
		my $c = 'IUCN_2010';
		my $t = 'text';
		push @elements, ['element', { name => $c,
					      type => $t,
					      minOccurs => "0",
					      maxOccurs => "1" } ];
	    }
	} else {
	    @elements = (['element', { name => "ogrGeometry",
				       type => "gml:GeometryPropertyType",
				       minOccurs => "0",
				       maxOccurs => "1" } ]);
	}
	xml_element('complexType', {name => $typename.'Type'},
		    ['complexContent', 
		     ['extension', { base => 'gml:AbstractFeatureType' }, 
		      ['sequence', \@elements
		       ]]]);
	xml_element('element', { name => $type->{Name}, 
				 type => 'ogr:'.$typename.'Type',
				 substitutionGroup => 'gml:_Feature' } );
    }

    xml_element('/schema', '>');
    select(STDOUT);
    close $out;    
    $header = WXS::header(cgi => $q, length => length(Encode::encode_utf8($var)), type => $config->{MIME});
    print $var;
}

sub GetCapabilities {
    my($version) = @_;
    my($out, $var);
    open($out,'>', \$var);
    select $out;
    print('<?xml version="1.0" encoding="UTF-8"?>',"\n");
    xml_element('wfs:WFS_Capabilities', 
		{ version => $version,
		  'xmlns:gml' => "http://www.opengis.net/gml",
		  'xmlns:wfs' => "http://www.opengis.net/wfs",
		  'xmlns:ows' => "http://www.opengis.net/ows",
		  'xmlns:xlink' => "http://www.w3.org/1999/xlink",
		  'xmlns:xsi' => "http://www.w3.org/2001/XMLSchema-instance",
		  'xmlns:ogc' => "http://www.opengis.net/ogc",
		  'xmlns' => "http://www.opengis.net/wfs",
		  'xsi:schemaLocation' => "http://www.opengis.net/wfs http://schemas.opengis.net/wfs/1.1.0/wfs.xsd" }, 
		'<');
    ServiceIdentification($version);
    ServiceProvider($version);
    OperationsMetadata($version);
    FeatureTypeList($version);
    Filter_Capabilities($version);
    xml_element('/wfs:WFS_Capabilities', '>');
    select(STDOUT);
    close $out;
    $header = WXS::header(cgi => $q, length => length(Encode::encode_utf8($var)), type => $config->{MIME});
    print $var;
}

sub ServiceIdentification {
    my($version) = @_;
    xml_element('ows:ServiceIdentification', '<');
    xml_element('ows:Title', 'WFS Server');
    xml_element('ows:Abstract');
    xml_element('ows:ServiceType', {codeSpace=>"OGC"}, 'OGC WFS');
    xml_element('ows:ServiceTypeVersion', $version);
    xml_element('ows:Fees');
    xml_element('ows:AccessConstraints');
    xml_element('/ows:ServiceIdentification', '>');
}

sub ServiceProvider {
    my($version) = @_;
    xml_element('ows:ServiceProvider', '<');
    xml_element('ows:ProviderName');
    xml_element('ows:ProviderSite', {'xlink:type'=>"simple", 'xlink:href'=>""});
    xml_element('ows:ServiceContact');
    xml_element('/ows:ServiceProvider', '>');
}

sub OperationsMetadata  {
    my($version) = @_;
    xml_element('ows:OperationsMetadata', '<');
    Operation($config, 'GetCapabilities', 
	      [{service => ['WFS']}, {AcceptVersions => ['1.1.0','1.0.0']}, {AcceptFormats => ['text/xml']}]);
    Operation($config, 'DescribeFeatureType', 
	      [{outputFormat => ['XMLSCHEMA','text/xml; subtype=gml/2.1.2','text/xml; subtype=gml/3.1.1']}]);
    Operation($config, 'GetFeature',
	      [{resultType => ['results']}, {outputFormat => ['text/xml; subtype=gml/3.1.1']}]);
    xml_element('/ows:OperationsMetadata', '>');
}

sub FeatureTypeList  {
    my($version) = @_;
    xml_element('FeatureTypeList', '<');
    xml_element('Operations', ['Operation', 'Query']);
    for my $type (@{$config->{FeatureTypeList}}) {
	if ($type->{Layer}) {
	    xml_element('FeatureType', [
					['Name', $type->{Name}],
					['Title', $type->{Title}],
					['Abstract', $type->{Abstract}],
					['DefaultSRS', $type->{DefaultSRS}],
					['OutputFormats', ['Format', 'text/xml; subtype=gml/3.1.1']],
					['ows:WGS84BoundingBox', {dimensions=>2}, 
					 [['ows:LowerCorner',$type->{LowerCorner}],
					  ['ows:UpperCorner',$type->{UpperCorner}]]]
					]);
	} else {
	    # restrict now to postgis databases
	    my @layers = layers($type->{dbi}, $type->{prefix});
	    for my $l (@layers) {
		xml_element('FeatureType', [
				            ['Name', $l->{Name}],
					    ['Title', $l->{Title}],
					    ['Abstract', $l->{Abstract}],
					    ['DefaultSRS', $l->{DefaultSRS}],
				            ['OutputFormats', ['Format', 'text/xml; subtype=gml/3.1.1']]
					    ]);
	    }
	}
    }
    xml_element('/FeatureTypeList', '>');
}

sub feature {
    my($typename) = @_;
    my $type;
    for my $t (@{$config->{FeatureTypeList}}) {
	if ($t->{Layer}) {
	    $type = $t, last if $t->{Name} eq $typename;
	} else {
	    next unless $typename =~ /^$t->{prefix}/;
	    # restrict now to postgis databases
	    my @layers = layers($t->{dbi}, $t->{prefix});
	    for my $l (@layers) {
		if ($l->{Name} eq $typename) {
		    $type = $t;
		    for (keys %$l) {
			$type->{$_} = $l->{$_};
		    }
		}
	    }
	    last if $type;
	}
    }
    return $type;
}

sub layers {
    my($dbi, $prefix) = @_;
    my($connect, $user, $pass) = split / /, $dbi;
    my $dbh = DBI->connect($connect, $user, $pass) or croak('no db');
    $dbh->{pg_enable_utf8} = 1;
    my $sth = $dbh->table_info( '', 'public', undef, "'TABLE','VIEW'" );
    my @tables;
    while (my $data = $sth->fetchrow_hashref) {
	#my $n = decode("utf8", $data->{TABLE_NAME});
	my $n = $data->{TABLE_NAME};
	$n =~ s/"//g;
	push @tables, $n;
    }
    my @layers;
    for my $table (@tables) {
	my $sth = $dbh->column_info( '', 'public', $table, '' );
	my %schema;
	my @l;
	while (my $data = $sth->fetchrow_hashref) {
	    #my $n = decode("utf8", $data->{COLUMN_NAME});
	    my $n = $data->{COLUMN_NAME};
	    $n =~ s/"//g;
	    $schema{$n} = $data->{TYPE_NAME};
	    push @l, $n if $data->{TYPE_NAME} eq 'geometry';	    
	}
	for my $geom (@l) {
	    my $sql = "select auth_name,auth_srid ".
		"from \"$table\" join spatial_ref_sys on srid=srid(\"$geom\") limit 1";
	    my $sth = $dbh->prepare($sql) or croak($dbh->errstr);
	    my $rv = $sth->execute or croak($dbh->errstr);
	    my($name,$srid)  = $sth->fetchrow_array;
	    $name = 'unknown' unless defined $name;
	    $srid = -1 unless defined $srid;
	    push @layers, { Title => "$table($geom)",
			    Name => "$prefix.$table.$geom",
			    Abstract => "Layer from $table in $prefix using column $geom",
			    DefaultSRS => "$name:$srid",
			    Table => $table,
			    GeometryColumn => $geom,
			    Schema => \%schema };
	}
    }
    return @layers;
}

sub Filter_Capabilities  {
    my($version) = @_;
    xml_element('ogc:Filter_Capabilities', '<');
    my @operands = ();
    for my $o (qw/Point LineString Polygon Envelope/) {
	push @operands, ['ogc:GeometryOperand', 'gml:'.$o];
    }
    my @operators = ();
    for my $o (qw/Equals Disjoint Touches Within Overlaps Crosses Intersects Contains DWithin Beyond BBOX/) {
	push @operators, ['ogc:SpatialOperator', { name => $o }];
    }
    xml_element('ogc:Spatial_Capabilities', 
		[['ogc:GeometryOperands', \@operands],
		 ['ogc:SpatialOperators', \@operators]]);
    @operators = ();
    for my $o (qw/LessThan GreaterThan LessThanEqualTo GreaterThanEqualTo EqualTo NotEqualTo Like Between/) {
	push @operators, ['ogc:ComparisonOperator', $o];
    }
    xml_element('ogc:Scalar_Capabilities', 
		[['ogc:LogicalOperators'],
		 ['ogc:ComparisonOperators', \@operators]]);
    xml_element('ogc:Id_Capabilities', ['ogc:FID']);
    xml_element('/ogc:Filter_Capabilities', '>');
}
