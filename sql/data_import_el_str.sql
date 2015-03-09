/*******************************/
/* SOURCES                     */
/*******************************/

INSERT INTO vtm.sources(name)
SELECT 'EL_STR'
WHERE NOT EXISTS ( SELECT id FROM vtm.sources WHERE name = 'EL_STR' );


/*******************************/
/* ENTITY_TYPES                */
/*******************************/

INSERT INTO vtm.entity_types(name,min_zoom,max_zoom,zindex)
SELECT 'street', 15, null, 5.0
WHERE NOT EXISTS ( SELECT id FROM vtm.entity_types WHERE name = 'street' );


/*******************************/
/* ENTITIES                    */
/*******************************/

INSERT INTO vtm.entities (name, type_id)
SELECT 	'el_str_entity_'||id as name,
		(SELECT id FROM vtm.entity_types WHERE name='street') as type_id
FROM 	"data_external"."el_str" as source
WHERE 	ST_Intersects(ST_Transform(ST_Force2D(source.geom),4326), ST_MakeEnvelope(12.3328,45.4365,12.3401,45.4401, 4326));


/*******************************/
/* EVENTS (geom)               */
/*******************************/

INSERT INTO vtm.events(entity_id, key, geovalue, date, source_id)
SELECT 	(SELECT id FROM vtm.entities WHERE name=('el_str_entity_'||source.id) LIMIT 1) as entity_id,
		'geom' as key,
		ST_Transform(ST_Force2D(source.geom),4326) as geovalue,
		2015 as date,
		(SELECT id FROM vtm.sources WHERE name='EL_STR') as source_id
FROM 	"data_external"."el_str" as source
WHERE 	ST_Intersects(ST_Transform(ST_Force2D(source.geom),4326), ST_MakeEnvelope(12.3328,45.4365,12.3401,45.4401, 4326));