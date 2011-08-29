//
//  CouchQuery.m
//  CouchCocoa
//
//  Created by Jens Alfke on 5/30/11.
//  Copyright 2011 Couchbase, Inc.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

// <http://wiki.apache.org/couchdb/HTTP_view_API#Querying_Options>


#import "CouchQuery.h"
#import "CouchDesignDocument.h"
#import "CouchInternal.h"


@interface CouchQueryEnumerator ()
- (id) initWithQuery: (CouchQuery*)query op: (RESTOperation*)op;
@end


@interface CouchQueryRow ()
- (id) initWithQuery: (CouchQuery*)query result: (id)result;
@end



@implementation CouchQuery


- (id) initWithQuery: (CouchQuery*)query {
    self = [super initWithParent: query.parent relativePath: query.relativePath];
    if (self) {
        _limit = query.limit;
        _skip = query.skip;
        self.startKey = query.startKey;
        self.endKey = query.endKey;
        self.key = query.key;
        _descending = query.descending;
        _prefetch = query.prefetch;
        self.keys = query.keys;
        _groupLevel = query.groupLevel;
    }
    return self;
}


@synthesize limit=_limit, skip=_skip, descending=_descending, startKey=_startKey, endKey=_endKey, key=_key,
            prefetch=_prefetch, keys=_keys, groupLevel=_groupLevel;


- (CouchDesignDocument*) designDocument {
    // The relativePath to a view URL will look like "_design/DOCNAME/_view/VIEWNAME"
    NSArray* path = [self.relativePath componentsSeparatedByString: @"/"];
    if (path.count >= 4 && [[path objectAtIndex: 0] isEqualToString: @"_design"])
        return [self.database designDocumentWithName: [path objectAtIndex: 1]];
    else
        return nil;
}


- (NSDictionary*) jsonToPost {
    if (_keys)
        return [NSDictionary dictionaryWithObject: _keys forKey: @"keys"];
    else
        return nil;
}


- (NSMutableDictionary*) requestParams {
    NSMutableDictionary* params = [NSMutableDictionary dictionary];
    if (_limit)
        [params setObject: [NSNumber numberWithUnsignedLong: _limit] forKey: @"?limit"];
    if (_skip)
        [params setObject: [NSNumber numberWithUnsignedLong: _skip] forKey: @"?skip"];
    if (_startKey)
        [params setObject: [RESTBody stringWithJSONObject: _startKey] forKey: @"?startkey"];
    if (_endKey)
        [params setObject: [RESTBody stringWithJSONObject: _endKey] forKey: @"?endkey"];
    if (_key)
        [params setObject: [RESTBody stringWithJSONObject: _key] forKey: @"?key"];
    if (_descending)
        [params setObject: @"true" forKey: @"?descending"];
    if (_prefetch)
        [params setObject: @"true" forKey: @"?include_docs"];
    if (_groupLevel > 0)
        [params setObject: [NSNumber numberWithUnsignedLong: _groupLevel] forKey: @"?group_level"];
    [params setObject: @"true" forKey: @"?update_seq"];
    return params;
}


- (RESTOperation*) start {
    NSDictionary* params = self.requestParams;
    NSDictionary* json = self.jsonToPost;
    if (json)
        return [self POSTJSON: json parameters: params];
    else
        return [self sendHTTP: @"GET" parameters: params];
}


- (CouchQueryEnumerator*) rows {
    [self cacheResponse: nil];
    return [self rowsIfChanged];
}


- (CouchQueryEnumerator*) rowsIfChanged {
    return [[self start] resultObject];
}


- (NSError*) operation: (RESTOperation*)op willCompleteWithError: (NSError*)error {
    error = [super operation: op willCompleteWithError: error];
    if (!error && op.httpStatus == 200) {
        NSArray* rows = $castIf(NSArray, [op.responseBody.fromJSON objectForKey: @"rows"]);
        if (rows) {
            [self cacheResponse: op];
            op.resultObject = [[[CouchQueryEnumerator alloc] initWithQuery: self
                                                                        op: op] autorelease];
        } else {
            Warn(@"Couldn't parse rows from CouchDB view response");
            error = [NSError errorWithDomain: CouchHTTPErrorDomain code: 500 userInfo:nil];
        }
    }
    return error;
}


- (CouchLiveQuery*) asLiveQuery {
    return [[[CouchLiveQuery alloc] initWithQuery: self] autorelease];
}


@end




@implementation CouchFunctionQuery


- (id) initWithDatabase: (CouchDatabase*)db
                    map: (NSString*)map
                 reduce: (NSString*)reduce
               language: (NSString*)language
{
    NSParameterAssert(map);
    self = [super initWithParent: db relativePath: @"_temp_view"];
    if (self != nil) {
        _viewDefinition = [[NSDictionary alloc] initWithObjectsAndKeys:
                               (language ?: kCouchLanguageJavaScript), @"language",
                               map, @"map",
                               reduce, @"reduce",  // may be nil
                               nil];
    }
    return self;
}


- (void) dealloc
{
    [_viewDefinition release];
    [super dealloc];
}


- (NSDictionary*) jsonToPost {
    return _viewDefinition;
}


@end



@implementation CouchLiveQuery

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver: self];
    [_op release];
    [super dealloc];
}


- (CouchQueryEnumerator*) rows {
    if (!_observing)
        [self start];
    // Have to return a copy because the enumeration has to start at item #0 every time
    return [[_rows copy] autorelease];
}


- (void) setRows:(CouchQueryEnumerator *)rows {
    [_rows autorelease];
    _rows = [rows retain];
}


- (RESTOperation*) start {
    if (!_op) {
        if (!_observing) {
            _observing = YES;
            self.database.tracksChanges = YES;
            [[NSNotificationCenter defaultCenter] addObserver: self 
                                                     selector: @selector(databaseChanged)
                                                         name: kCouchDatabaseChangeNotification 
                                                       object: self.database];
        }
        COUCHLOG(@"CouchLiveQuery: Starting...");
        _op = [[super start] retain];
        [_op start];
    }
    return _op;
}


- (void) databaseChanged {
    [self start];
}


- (NSError*) operation: (RESTOperation*)op willCompleteWithError: (NSError*)error {
    error = [super operation: op willCompleteWithError: error];

    if (op == _op) {
        COUCHLOG(@"CouchLiveQuery: ...Finished (status=%i)", op.httpStatus);
        [_op release];
        _op = nil;
        CouchQueryEnumerator* rows = op.resultObject;
        if (rows && ![rows isEqual: _rows]) {
            COUCHLOG(@"CouchLiveQuery: ...Rows changed! (now %lu)", (unsigned long)rows.count);
            self.rows = rows;   // Triggers KVO notification
            self.prefetch = NO;   // (prefetch disables conditional GET shortcut on next fetch)
        }
    }
    
    return error;
}


@end




@implementation CouchQueryEnumerator


@synthesize totalCount=_totalCount, sequenceNumber=_sequenceNumber;


- (id) initWithQuery: (CouchQuery*)query
                rows: (NSArray*)rows
          totalCount: (NSUInteger)totalCount
      sequenceNumber: (NSUInteger)sequenceNumber
{
    NSParameterAssert(query);
    self = [super init];
    if (self ) {
        if (!rows) {
            [self release];
            return nil;
        }
        _query = [query retain];
        _rows = [rows retain];
        _totalCount = totalCount;
        _sequenceNumber = sequenceNumber;
    }
    return self;
}

- (id) initWithQuery: (CouchQuery*)query op: (RESTOperation*)op {
    NSDictionary* result = $castIf(NSDictionary, op.responseBody.fromJSON);
    return [self initWithQuery: query
                          rows: $castIf(NSArray, [result objectForKey: @"rows"])
                    totalCount: [[result objectForKey: @"total_rows"] intValue]
                sequenceNumber: [[result objectForKey: @"update_seq"] intValue]];
}

- (id) copyWithZone: (NSZone*)zone {
    return [[[self class] alloc] initWithQuery: _query
                                          rows: _rows
                                    totalCount: _totalCount
                                sequenceNumber: _sequenceNumber];
}


- (void) dealloc
{
    [_query release];
    [_rows release];
    [super dealloc];
}


- (BOOL) isEqual:(id)object {
    if (object == self)
        return YES;
    if (![object isKindOfClass: [CouchQueryEnumerator class]])
        return NO;
    CouchQueryEnumerator* otherEnum = object;
    return [otherEnum->_rows isEqual: _rows];
}


- (NSUInteger) count {
    return _rows.count;
}


- (CouchQueryRow*) rowAtIndex: (NSUInteger)index {
    return [[[CouchQueryRow alloc] initWithQuery: _query
                                          result: [_rows objectAtIndex:index]]
            autorelease];
}


- (CouchQueryRow*) nextRow {
    if (_nextRow >= _rows.count)
        return nil;
    return [self rowAtIndex:_nextRow++];
}


- (id) nextObject {
    return [self nextRow];
}


@end




@implementation CouchQueryRow


- (id) initWithQuery: (CouchQuery*)query result: (id)result {
    self = [super init];
    if (self) {
        if (![result isKindOfClass: [NSDictionary class]]) {
            Warn(@"Unexpected row value in view results: %@", result);
            [self release];
            return nil;
        }
        _query = [query retain];
        _result = [result retain];
    }
    return self;
}


@synthesize query=_query;

- (id) key                          {return [_result objectForKey: @"key"];}
- (id) value                        {return [_result objectForKey: @"value"];}
- (NSString*) documentID            {return [_result objectForKey: @"id"];}
- (NSDictionary*) documentProperties  {return [_result objectForKey: @"doc"];}

- (NSString*) documentRevision {
    // Get the revision id from either the embedded document contents,
    // or the 'rev' value key:
    NSString* rev = [[_result objectForKey: @"doc"] objectForKey: @"_rev"];
    if (!rev)
        rev = [$castIf(NSDictionary, self.value) objectForKey: @"rev"];
    return rev;
}


- (id) keyAtIndex: (NSUInteger)index {
    id key = [_result objectForKey: @"key"];
    if ([key isKindOfClass:[NSArray class]])
        return (index < [key count]) ? [key objectAtIndex: index] : nil;
    else
        return (index == 0) ? key : nil;
}

- (id) key0                         {return [self keyAtIndex: 0];}
- (id) key1                         {return [self keyAtIndex: 1];}
- (id) key2                         {return [self keyAtIndex: 2];}
- (id) key3                         {return [self keyAtIndex: 3];}


- (CouchDocument*) document {
    NSString* docID = [_result objectForKey: @"id"];
    if (!docID)
        return nil;
    CouchDocument* doc = [_query.database documentWithID: docID];
    [doc loadCurrentRevisionFrom: self];
    return doc;
}


- (NSString*) description {
    return [NSString stringWithFormat: @"%@[key=%@; value=%@; id=%@]",
            [self class],
            [RESTBody stringWithJSONObject: self.key],
            [RESTBody stringWithJSONObject: self.value],
            self.documentID];
}


@end
