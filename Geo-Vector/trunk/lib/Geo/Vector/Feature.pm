package Geo::Vector::Feature;
# @brief A root class for complex features.

use strict;
use warnings;
use UNIVERSAL qw(isa);
use Carp;
use Encode;
use Geo::GDAL;
use Geo::OGC::Geometry;

sub new {
    my $package = shift;
    my %params = @_;
    my $self = { properties => {} };
    bless $self => (ref($package) or $package);
    $self->{properties}{class} = $params{class} if exists $params{class};
    $self->{properties}{class} = 'Feature' unless $self->{properties}{class};
    $self->{OGRDefn} = Geo::OGR::FeatureDefn->new();
    $self->{OGRFeature} = Geo::OGR::Feature->new($self->{OGRDefn});
    $self->GeoJSON($params{GeoJSON}) if ($params{GeoJSON});
    return $self;
}

sub _Geometry {
    my($self, $object) = @_;
    # set type 25D depending on the actual dimension
    my $geom;
    if ($object->{type} eq 'GeometryCollection') {
	$geom = Geo::OGR::Geometry->create( Type => $object->{type} );
	for my $g (@{$object->{geometries}}) {
	    $geom->AddGeometry($self->_Geometry($g));
	}
    } else { # assuming a non-collection geometry
	$geom = Geo::OGR::Geometry->create( Type => $object->{type}, Points => $object->{coordinates} );
    }
    return $geom;
}

sub GeoJSON {
    my($self, $object) = @_;
    if ($object) {
	if ($object->{type} eq 'Feature') {
	    $self->{OGRFeature}->SetGeometry( $self->_Geometry($object->{geometry}) );
	    my $to = $self->{properties};
	    my $from = $object->{properties};
	    for my $field (keys %$from) {
		$to->{$field} = $from->{$field};
	    }
	} else { # assuming a geometry
	    $self->{OGRFeature}->SetGeometry( $self->_Geometry($object) );
	}
    } else {
	$object->{type} = 'Feature';
	my $from = $self->{properties};
	my $to = $object->{properties} = {};
	for my $field (keys %$from) {
	    $to->{$field} = $from->{$field};
	}
	my $geom = $self->{OGRFeature}->GetGeometryRef();
	my $type = $geom->GeometryType;
	$type =~ s/25D//;
	if ($type =~ /Collection/) {
	    $object->{geometry}{type} = $type;
	    $object->{geometry}{geometries} = [];
	    for my $i (0..$geom->GetGeometryCount-1) {
		my $g = $geom->GetGeometryRef($i);
		my $type = $g->GeometryType;
		$type =~ s/25D//;
		my $geometry = { type => $type, coordinates => $g->Points };
		push @{$object->{geometry}{geometries}}, $geometry;
	    }
	} else {	    
	    $object->{geometry}{type} = $type;
	    $object->{geometry}{coordinates} = $geom->Points;
	}
    }
    return $object;
}

sub Schema {
    my($self) = @_;
    my @fields = ({ Name => 'class', Type => 'String' });
    for my $f (sort keys %{$self->{properties}}) {
	next if $f eq 'class';
	push @fields, { Name => $f, Type => 'String' };
    }
    my $geom = $self->{OGRFeature}->GetGeometryRef;
    my $type = $geom ? $geom->GeometryType : '';
    return {
	GeometryType => $type,
	Fields => \@fields,
    }
}

sub DeleteField {
    my($self, $field) = @_;
    delete $self->{properties}{$field};
}

sub Field {
    my($self, $field, $value) = @_;
    $self->{properties}{$field} = $value if defined $value;
    $self->{properties}{$field};
}
*GetField = *Field;
*SetField = *Field;

sub Geometry {
    my($self, $geom) = @_;
    $self->{OGRFeature}->SetGeometry($geom) if $geom;
    $self->{OGRFeature}->GetGeometryRef();
}
*SetGeometry = *Geometry;
*GetGeometryRef = *Geometry;

sub FID {
    my($self, $fid) = @_;
    $self->{OGRFeature}->SetFID($fid) if defined $fid;
    $self->{OGRFeature}->GetFID;
}
*SetFID = *FID;
*GetFID = *FID;

sub Row {
    my($self, %row) = @_;
    for my $key (keys %row) {
	if ($key eq 'FID') {
	    $self->FID($row{FID});
	} elsif ($key eq 'Geometry') {
	    $self->Geometry($row{Geometry});
	} else {
	    $self->Field($row{$key});
	}
    }
    %row = ( FID => $self->FID, Geometry => $self->Geometry );
    for my $key (keys %{$self->{properties}}) {
	$row{$key} = $self->{properties}{$key};
    }
    return \%row;
}

1;
