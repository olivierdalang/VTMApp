-- Table: vtm.entities

DROP TABLE IF EXISTS vtm.entity_types CASCADE;
CREATE TABLE vtm.entity_types
(
  id serial NOT NULL PRIMARY KEY,
  name text UNIQUE,
  min_zoom int,
  max_zoom int,
  zindex real
);
INSERT INTO vtm.entity_types(id,name,zindex) VALUES (0,'autogenerated',10000.0);


DROP TABLE IF EXISTS vtm.entities CASCADE;
CREATE TABLE vtm.entities
(
  id serial NOT NULL PRIMARY KEY,
  name text,
  type_id integer NOT NULL REFERENCES vtm.entity_types ON DELETE CASCADE
);
COMMENT ON TABLE vtm.entities IS 'Cette table contient les entités historiques.';

-- Table: vtm.events
DROP TABLE IF EXISTS vtm.related_entities CASCADE;
CREATE TABLE vtm.related_entities
(
  id serial NOT NULL PRIMARY KEY,
  a_id integer NOT NULL REFERENCES vtm.entities ON DELETE CASCADE,
  b_id integer NOT NULL REFERENCES vtm.entities ON DELETE CASCADE
);
COMMENT ON TABLE vtm.related_entities IS 'Cette table contient les entités liées par une relation de succession.';

-- Table: vtm.sources
DROP TABLE IF EXISTS vtm.sources CASCADE;
CREATE TABLE vtm.sources
(
  id serial NOT NULL PRIMARY KEY,
  name text UNIQUE
);
COMMENT ON TABLE vtm.sources IS 'Cette table contient les documents sources.';

-- Table: vtm.events
DROP TABLE IF EXISTS vtm.events CASCADE;
CREATE TABLE vtm.events
(
  id serial NOT NULL PRIMARY KEY,
  entity_id integer NOT NULL REFERENCES vtm.entities ON DELETE CASCADE,
  description text,
  key text NOT NULL,
  value text,
  geovalue geometry(Geometry,4326),
  date integer,
  computed_date_start integer,
  computed_date_end integer,
  --computed_size real,
  source_id integer REFERENCES vtm.sources ON DELETE SET NULL,
  source_description text
);
CREATE INDEX "events_spatial_index" ON "vtm"."events" USING GIST ( geovalue );
COMMENT ON TABLE vtm.events IS 'Cette table contient les évenements qui changent les propriétés des entités.';



/*
TRIGGERS ET FONCTIONS pour gerer la synchro du champ geovalue.
*/
DROP FUNCTION IF EXISTS vtm.manage_geovalue_field();
CREATE FUNCTION vtm.manage_geovalue_field() RETURNS trigger AS    
$$
    BEGIN
      IF TG_OP='INSERT' THEN
        IF NEW.geovalue IS NOT NULL THEN
          IF NEW.key IS NOT NULL AND NEW.key != 'geom' THEN
            RAISE EXCEPTION 'Key must be ''geom'' or NULL if a geovalue is provided !';
          END IF;
          NEW.key = 'geom';
          NEW.value = ST_AsText(NEW.geovalue);
          --NEW.computed_size = GREATEST(ST_XMax(NEW.geovalue)-ST_XMin(NEW.geovalue),ST_YMax(NEW.geovalue)-ST_YMin(NEW.geovalue));
        END IF;
        RETURN NEW;

      ELSIF TG_OP='UPDATE' THEN

        IF NEW.key = 'geom' AND NEW.value != OLD.value AND (NEW.geovalue=OLD.geovalue OR (NEW.geovalue IS NULL AND OLD.geovalue IS NULL)) THEN
          NEW.geovalue = ST_GeometryFromText(NEW.value, 4326);
        END IF;

        IF NEW.geovalue IS NOT NULL THEN
          IF NEW.key IS NOT NULL AND NEW.key != 'geom' THEN
            RAISE EXCEPTION 'Key must be ''geom'' or NULL if a geovalue is provided !';
          END IF;
          NEW.key = 'geom';
          NEW.value = ST_AsText(NEW.geovalue);
          --NEW.computed_size = GREATEST(ST_XMax(NEW.geovalue)-ST_XMin(NEW.geovalue),ST_YMax(NEW.geovalue)-ST_YMin(NEW.geovalue));
        END IF;
        RETURN NEW;

      ELSE
        RETURN NULL;      
      END IF;

    END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER events_i BEFORE INSERT OR UPDATE OF "key","geovalue","value" ON vtm.events FOR EACH ROW
    EXECUTE PROCEDURE vtm.manage_geovalue_field();

/*
TRIGGERS ET FONCTIONS pour créer une entity si entity_id n'est pas fourni
*/

DROP FUNCTION IF EXISTS vtm.autogenerate_entity();
CREATE FUNCTION vtm.autogenerate_entity() RETURNS trigger AS    
$$
    DECLARE
        new_entity_id integer;
    BEGIN
        IF NEW.entity_id IS NULL THEN
          INSERT INTO "vtm"."entities"("name","type_id") VALUES ('entity_'||lpad(currval('vtm.entities_id_seq')::text,6,'0'), 0);
          NEW.entity_id = ( SELECT currval('vtm.entities_id_seq') );
        END IF;
        RETURN NEW;
    END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER events_bi BEFORE INSERT OR UPDATE OF entity_id ON vtm.events FOR EACH ROW
    EXECUTE PROCEDURE vtm.autogenerate_entity();


/*
TRIGGERS ET FONCTIONS pour recalculer les dates lorsque des evenements sont ajoutés ou supprimés.
*/

DROP FUNCTION IF EXISTS vtm.events_reset_computed_dates();
CREATE FUNCTION vtm.events_reset_computed_dates() RETURNS trigger AS    
$$
    BEGIN

      IF TG_OP='INSERT' OR TG_OP='UPDATE' THEN
        PERFORM vtm.query_reset_computed_dates(NEW.entity_id, NEW.key);
      END IF;
      
      IF TG_OP='UPDATE' OR TG_OP='DELETE' THEN
        PERFORM vtm.query_reset_computed_dates(OLD.entity_id, OLD.key);
      END IF;       

      IF TG_OP='UPDATE' OR TG_OP='INSERT' THEN
        RETURN NEW;
      ELSE
        RETURN NULL;
      END IF;

    END;
$$ LANGUAGE plpgsql;

DROP FUNCTION IF EXISTS vtm.query_reset_computed_dates(current_entity_id int, current_key text);
CREATE FUNCTION vtm.query_reset_computed_dates(current_entity_id int, current_key text) RETURNS VOID AS
$$
    BEGIN
      UPDATE vtm.events as d
      SET   computed_date_start = CASE WHEN sub.prev_date IS NULL THEN NULL ELSE (sub.prev_date+d.date)/2.0 END,
            computed_date_end = CASE WHEN sub.next_date IS NULL THEN NULL ELSE (sub.next_date+d.date)/2.0 END
      FROM (
          SELECT  array_agg(id) as ids,
                  date,
                  lag(date, 1, NULL) OVER (ORDER BY date) as prev_date,
                  lead(date, 1, NULL) OVER (ORDER BY date) as next_date
          FROM vtm.events
          WHERE (entity_id=current_entity_id OR entity_id IN (SELECT b_id FROM vtm.related_entities WHERE a_id=current_entity_id)) AND (current_key IS NULL OR key=current_key)
          GROUP BY date, key
          ORDER BY date ASC
        ) as sub
        WHERE entity_id=current_entity_id AND (current_key IS NULL OR key=current_key) AND d.id = ANY(sub.ids);
    END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER reset_date_for_events AFTER INSERT OR UPDATE OF "date","key","entity_id" OR DELETE ON vtm.events FOR EACH ROW
    EXECUTE PROCEDURE vtm.events_reset_computed_dates();


/*
TRIGGERS ET FONCTIONS pour recalculer les dates lorsque des relations sont ajoutés ou supprimés.
*/

DROP FUNCTION IF EXISTS vtm.relations_reset_computed_dates();
CREATE FUNCTION vtm.relations_reset_computed_dates() RETURNS trigger AS    
$$
    BEGIN

      IF TG_OP='INSERT' OR TG_OP='UPDATE' THEN
        PERFORM vtm.query_reset_computed_dates(NEW.a_id, NULL);
      END IF;
      
      IF TG_OP='UPDATE' OR TG_OP='DELETE' THEN
        PERFORM vtm.query_reset_computed_dates(OLD.a_id, NULL);
      END IF;       

      IF TG_OP='UPDATE' OR TG_OP='INSERT' THEN
        RETURN NEW;
      ELSE
        RETURN OLD;
      END IF;

    END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER reset_date_for_relations AFTER INSERT OR UPDATE OF "a_id","b_id" OR DELETE ON vtm.related_entities FOR EACH ROW
    EXECUTE PROCEDURE vtm.relations_reset_computed_dates();



