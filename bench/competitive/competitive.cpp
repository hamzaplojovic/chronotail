#include "chronotail.h"
#include "nanots.h"
#include "sqlite3.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <mutex>
#include <numeric>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

using Clock = std::chrono::steady_clock;
namespace fs = std::filesystem;
static std::atomic<uint64_t> consumed{0};

struct Point { int64_t ts; double value; };
static_assert(sizeof(Point)==16, "logical point payload must be exactly 16 bytes");
struct Metrics { double seconds=0; uint64_t operations=0, points=0, bytes=0; std::vector<uint64_t> latency, sync_latency; };

static void fail(const std::string& s) { throw std::runtime_error(s); }
static void ct_ok(int rc, const char* where) { if (rc != CT_OK) fail(std::string(where)+": "+ct_error_string(rc)); }
static void sql_ok(int rc, sqlite3* db, const char* where) { if (rc != SQLITE_OK && rc != SQLITE_DONE && rc != SQLITE_ROW) fail(std::string(where)+": "+(db?sqlite3_errmsg(db):"sqlite error")); }
static uint64_t ns(Clock::time_point a, Clock::time_point b) { return std::chrono::duration_cast<std::chrono::nanoseconds>(b-a).count(); }
static uint64_t splitmix(uint64_t& x) { uint64_t z=(x+=0x9e3779b97f4a7c15ULL); z=(z^(z>>30))*0xbf58476d1ce4e5b9ULL; z=(z^(z>>27))*0x94d049bb133111ebULL; return z^(z>>31); }
struct Sampler {
  uint64_t state=0x123456789abcdef0ULL, next=317;
  bool take(uint64_t i) { if(i!=next)return false;next+=512+(splitmix(state)&1023);return true; }
};
static double random_value(uint64_t& state) { uint64_t bits=(splitmix(state)>>12)|0x3ff0000000000000ULL; double d; std::memcpy(&d,&bits,8); return d-1.0; }
static double value_for(uint64_t i, bool random, uint64_t& state) { return random ? random_value(state) : 20.0 + double(i)*0.000001 + std::sin(double(i)*0.0001); }
static uint64_t percentile(std::vector<uint64_t> v, double p) { if(v.empty()) return 0; std::sort(v.begin(),v.end()); return v[std::min(v.size()-1,size_t(p*double(v.size()-1)))]; }
static uint64_t files_size(const std::string& path) {
  uint64_t n=0; fs::path p(path), dir=p.parent_path().empty()?".":p.parent_path(); std::string base=p.filename().string();
  for(auto& e: fs::directory_iterator(dir)) if(e.is_regular_file() && e.path().filename().string().rfind(base,0)==0) n+=e.file_size();
  return n;
}
static void remove_db(const std::string& path) {
  fs::path p(path), dir=p.parent_path().empty()?".":p.parent_path(); std::string base=p.filename().string();
  if(!fs::exists(dir)) fs::create_directories(dir);
  for(auto& e: fs::directory_iterator(dir)) if(e.path().filename().string().rfind(base,0)==0) fs::remove(e.path());
}

struct Sqlite {
  sqlite3* db=nullptr; sqlite3_stmt* insert=nullptr;
  Sqlite(const std::string& path, bool create, bool durable=true) {
    sql_ok(sqlite3_open_v2(path.c_str(), &db, SQLITE_OPEN_READWRITE|(create?SQLITE_OPEN_CREATE:0)|SQLITE_OPEN_NOMUTEX, nullptr),db,"sqlite open");
    sqlite3_busy_timeout(db, 30000);
    if(create) { exec("PRAGMA journal_mode=WAL"); exec(durable?"PRAGMA synchronous=FULL":"PRAGMA synchronous=OFF"); }
    exec("PRAGMA temp_store=MEMORY"); exec("PRAGMA cache_size=-65536"); exec("PRAGMA mmap_size=1073741824");
    if(create) exec("CREATE TABLE points (series_id INTEGER NOT NULL, ts INTEGER NOT NULL, value REAL NOT NULL, PRIMARY KEY(series_id, ts))");
  }
  ~Sqlite(){ if(insert) sqlite3_finalize(insert); if(db) sqlite3_close(db); }
  void exec(const char* s){ char* err=nullptr; int rc=sqlite3_exec(db,s,nullptr,nullptr,&err); if(rc!=SQLITE_OK){std::string m=err?err:"error";sqlite3_free(err);fail(m);} }
  void prepare_insert(){ sql_ok(sqlite3_prepare_v2(db,"INSERT INTO points VALUES(?,?,?)",-1,&insert,nullptr),db,"prepare insert"); }
  void add(int series, int64_t ts, double value){ sqlite3_bind_int(insert,1,series);sqlite3_bind_int64(insert,2,ts);sqlite3_bind_double(insert,3,value);sql_ok(sqlite3_step(insert),db,"insert");sqlite3_reset(insert);sqlite3_clear_bindings(insert); }
};

static uint32_t nano_block(uint64_t logical_points) {
  uint64_t size=16 + logical_points*80; if(size>UINT32_MAX) fail("NanoTS block exceeds uint32 size"); return uint32_t(size);
}

static Metrics append_chrono(const std::string& path,uint64_t count,int nseries,uint64_t boundary,bool compressed,bool random) {
  remove_db(path); ct_handle* h=nullptr; ct_ok(ct_open_writer(path.data(),path.size(),compressed?CT_CODEC_COMPRESSED:CT_CODEC_RAW,&h),"ct_open_writer");
  Metrics m; m.operations=count;m.points=count;uint64_t rng=1;Sampler sampler;std::vector<std::string> series_names;for(int s=0;s<nseries;s++)series_names.push_back("series-"+std::to_string(s));auto begin=Clock::now();
  for(uint64_t i=0;i<count;i++) { int s=i%nseries;const auto&series=series_names[s];int64_t ts=i/nseries;double v=value_for(i,random,rng);bool sampled=sampler.take(i);Clock::time_point a;if(sampled)a=Clock::now();ct_ok(ct_append(h,series.data(),series.size(),&ts,&v,1),"ct_append");if(sampled)m.latency.push_back(ns(a,Clock::now()));
    if(boundary && (i+1)%boundary==0){auto x=Clock::now();ct_ok(ct_checkpoint(h,1),"ct_checkpoint");m.sync_latency.push_back(ns(x,Clock::now()));}
  }
  auto x=Clock::now();ct_ok(ct_checkpoint(h,boundary?1:0),"ct final checkpoint");m.sync_latency.push_back(ns(x,Clock::now()));ct_ok(ct_close(h),"ct_close");m.seconds=std::chrono::duration<double>(Clock::now()-begin).count();m.bytes=files_size(path);return m;
}
static Metrics append_nano(const std::string& path,uint64_t count,int nseries,uint64_t boundary,bool random) {
  remove_db(path); uint64_t per_series_window=boundary?std::max<uint64_t>(1,boundary/nseries):(count+nseries-1)/nseries; uint32_t bs=nano_block(per_series_window); uint64_t per=(count+nseries-1)/nseries; uint32_t blocks=uint32_t(nseries*((per+per_series_window-1)/per_series_window));
  nanots_writer::allocate(path,bs,blocks); Metrics m;m.operations=count;m.points=count;uint64_t rng=1;Sampler sampler;auto begin=Clock::now();
  { nanots_writer w(path); std::vector<write_context> contexts;contexts.reserve(nseries);for(int s=0;s<nseries;s++)contexts.push_back(w.create_write_context("series-"+std::to_string(s),"benchmark"));
    for(uint64_t i=0;i<count;i++){int s=i%nseries;Point p{int64_t(i/nseries),value_for(i,random,rng)};bool sampled=sampler.take(i);Clock::time_point a;if(sampled)a=Clock::now();w.write(contexts[s],reinterpret_cast<uint8_t*>(&p),sizeof(p),0,p.ts);if(sampled)m.latency.push_back(ns(a,Clock::now()));}
  }
  m.seconds=std::chrono::duration<double>(Clock::now()-begin).count();m.bytes=files_size(path);return m;
}
static Metrics append_sqlite(const std::string& path,uint64_t count,int nseries,uint64_t boundary,bool random) {
  remove_db(path);Metrics m;m.operations=count;m.points=count;uint64_t rng=1;Sampler sampler;auto begin=Clock::now();
  {Sqlite db(path,true,boundary!=0);db.prepare_insert();db.exec("BEGIN IMMEDIATE");for(uint64_t i=0;i<count;i++){int s=i%nseries;int64_t ts=i/nseries;double v=value_for(i,random,rng);bool sampled=sampler.take(i);Clock::time_point a;if(sampled)a=Clock::now();db.add(s,ts,v);if(sampled)m.latency.push_back(ns(a,Clock::now()));if(boundary&&(i+1)%boundary==0){auto x=Clock::now();db.exec("COMMIT");m.sync_latency.push_back(ns(x,Clock::now()));db.exec("BEGIN IMMEDIATE");}}auto x=Clock::now();db.exec("COMMIT");m.sync_latency.push_back(ns(x,Clock::now()));db.exec("PRAGMA wal_checkpoint(TRUNCATE)");}
  m.seconds=std::chrono::duration<double>(Clock::now()-begin).count();m.bytes=files_size(path);return m;
}

static Metrics build(const std::string& engine,const std::string& path,uint64_t count,int nseries,bool compressed,bool random,uint64_t boundary=0){if(engine=="chronotail")return append_chrono(path,count,nseries,boundary,compressed,random);if(engine=="nanots")return append_nano(path,count,nseries,boundary,random);if(engine=="sqlite")return append_sqlite(path,count,nseries,boundary,random);fail("unknown engine");return{};}

static uint64_t verify_db(const std::string& engine,const std::string& path,uint64_t expected,int nseries) {
  uint64_t count=0,hash=0;
  if(engine=="chronotail"){ct_handle*h=nullptr;ct_ok(ct_open_reader(path.data(),path.size(),&h),"verify open");for(int s=0;s<nseries;s++){std::string series="series-"+std::to_string(s);size_t cap=(expected+nseries-1)/nseries,n=cap;std::vector<int64_t>ts(cap);std::vector<double>v(cap);ct_ok(ct_range(h,series.data(),series.size(),INT64_MIN,INT64_MAX,ts.data(),v.data(),cap,&n),"verify range");count+=n;for(size_t i=0;i<n;i++)hash^=uint64_t(ts[i])+std::bit_cast<uint64_t>(v[i]);}ct_ok(ct_close(h),"verify close");}
  else if(engine=="nanots"){for(int s=0;s<nseries;s++){nanots_iterator it(path,"series-"+std::to_string(s));it.reset();while(it.valid()){const auto&f=*it;if(f.size!=16)fail("NanoTS payload size");Point p;std::memcpy(&p,f.data,16);if(p.ts!=f.timestamp)fail("NanoTS timestamp mismatch");hash^=uint64_t(p.ts)+std::bit_cast<uint64_t>(p.value);count++;++it;}}}
  else {Sqlite db(path,false);sqlite3_stmt*q=nullptr;sql_ok(sqlite3_prepare_v2(db.db,"SELECT ts,value FROM points ORDER BY series_id,ts",-1,&q,nullptr),db.db,"verify prepare");while(sqlite3_step(q)==SQLITE_ROW){auto t=sqlite3_column_int64(q,0);double v=sqlite3_column_double(q,1);hash^=uint64_t(t)+std::bit_cast<uint64_t>(v);count++;}sqlite3_finalize(q);}
  consumed.fetch_xor(hash, std::memory_order_relaxed);if(count!=expected)fail("verification count mismatch: "+std::to_string(count)+" != "+std::to_string(expected));return hash;
}

static Metrics query_chrono(const std::string& path,uint64_t count,int width,uint64_t dataset,uint64_t seed){ct_handle*h=nullptr;ct_ok(ct_open_reader(path.data(),path.size(),&h),"query open");Metrics m;m.operations=count;m.points=count*width;std::vector<int64_t>ts(width);std::vector<double>v(width);uint64_t rng=seed,hash=0;auto begin=Clock::now();for(uint64_t i=0;i<count;i++){int64_t start=splitmix(rng)%(dataset-width+1);size_t n=width;auto a=Clock::now();ct_ok(ct_range(h,"series-0",8,start,start+width-1,ts.data(),v.data(),width,&n),"query range");auto b=Clock::now();if(n!=(size_t)width)fail("chrono query count");for(size_t j=0;j<n;j++)hash^=uint64_t(ts[j])+std::bit_cast<uint64_t>(v[j]);m.latency.push_back(ns(a,b));}m.seconds=std::chrono::duration<double>(Clock::now()-begin).count();ct_ok(ct_close(h),"query close");consumed.fetch_xor(hash, std::memory_order_relaxed);return m;}
static Metrics query_nano(const std::string& path,uint64_t count,int width,uint64_t dataset,uint64_t seed){nanots_iterator it(path,"series-0");Metrics m;m.operations=count;m.points=count*width;uint64_t rng=seed,hash=0;auto begin=Clock::now();for(uint64_t i=0;i<count;i++){int64_t start=splitmix(rng)%(dataset-width+1);auto a=Clock::now();if(!it.find(start))fail("nano find");for(int j=0;j<width;j++){if(!it.valid())fail("nano short query");Point p;std::memcpy(&p,it->data,16);hash^=uint64_t(p.ts)+std::bit_cast<uint64_t>(p.value);if(j+1<width)++it;}auto b=Clock::now();m.latency.push_back(ns(a,b));}m.seconds=std::chrono::duration<double>(Clock::now()-begin).count();consumed.fetch_xor(hash, std::memory_order_relaxed);return m;}
static Metrics query_sqlite(const std::string& path,uint64_t count,int width,uint64_t dataset,uint64_t seed){Sqlite db(path,false);sqlite3_stmt*q=nullptr;sql_ok(sqlite3_prepare_v2(db.db,"SELECT ts,value FROM points WHERE series_id=0 AND ts>=? ORDER BY ts LIMIT ?",-1,&q,nullptr),db.db,"query prepare");Metrics m;m.operations=count;m.points=count*width;uint64_t rng=seed,hash=0;auto begin=Clock::now();for(uint64_t i=0;i<count;i++){int64_t start=splitmix(rng)%(dataset-width+1);sqlite3_bind_int64(q,1,start);sqlite3_bind_int(q,2,width);auto a=Clock::now();int n=0;while(sqlite3_step(q)==SQLITE_ROW){auto t=sqlite3_column_int64(q,0);double v=sqlite3_column_double(q,1);hash^=uint64_t(t)+std::bit_cast<uint64_t>(v);n++;}auto b=Clock::now();if(n!=width)fail("sqlite short query");m.latency.push_back(ns(a,b));sqlite3_reset(q);sqlite3_clear_bindings(q);}m.seconds=std::chrono::duration<double>(Clock::now()-begin).count();sqlite3_finalize(q);consumed.fetch_xor(hash, std::memory_order_relaxed);return m;}
static Metrics query(const std::string&e,const std::string&p,uint64_t n,int w,uint64_t ds,uint64_t seed){if(e=="chronotail")return query_chrono(p,n,w,ds,seed);if(e=="nanots")return query_nano(p,n,w,ds,seed);return query_sqlite(p,n,w,ds,seed);}

struct Concurrent {Metrics writer,reader;};
static Concurrent concurrent_chrono(const std::string&path,int readers,int seconds,uint64_t base){build("chronotail",path,base,1,false,false,65536);std::atomic<bool>go=false,stop=false;std::atomic<uint64_t>writes=0,queries=0;std::mutex lm;std::vector<uint64_t>lat;std::vector<std::thread>rt;for(int r=0;r<readers;r++)rt.emplace_back([&,r]{ct_handle*h=nullptr;ct_ok(ct_open_reader(path.data(),path.size(),&h),"reader open");uint64_t rng=r+7,hash=0;std::vector<int64_t>ts(100);std::vector<double>v(100);while(!go.load()){}while(!stop.load()){int64_t st=splitmix(rng)%(base-99);size_t n=100;auto a=Clock::now();ct_ok(ct_range(h,"series-0",8,st,st+99,ts.data(),v.data(),100,&n),"concurrent range");auto b=Clock::now();hash^=uint64_t(ts[0]);queries++;if((queries.load()&255)==0){std::lock_guard<std::mutex>g(lm);lat.push_back(ns(a,b));}}consumed.fetch_xor(hash, std::memory_order_relaxed);ct_close(h);});ct_handle*w=nullptr;ct_ok(ct_open_writer(path.data(),path.size(),CT_CODEC_RAW,&w),"writer reopen");auto begin=Clock::now();go=true;uint64_t i=base;while(std::chrono::duration<double>(Clock::now()-begin).count()<seconds){int64_t ts=i;double v=double(i);ct_ok(ct_append(w,"series-0",8,&ts,&v,1),"concurrent append");i++;writes++;if((i-base)%65536==0)ct_ok(ct_checkpoint(w,1),"concurrent checkpoint");}ct_ok(ct_checkpoint(w,1),"final checkpoint");stop=true;for(auto&t:rt)t.join();ct_close(w);double elapsed=std::chrono::duration<double>(Clock::now()-begin).count();return{{elapsed,writes.load(),writes.load(),files_size(path)},{elapsed,queries.load(),queries.load()*100,0,lat,{}}};}

static Concurrent concurrent_nano(const std::string&path,int readers,int seconds,uint64_t base){remove_db(path);uint64_t extra=50000000,window=65536;uint32_t bs=nano_block(window);uint32_t blocks=uint32_t((base+extra+window-1)/window);nanots_writer::allocate(path,bs,blocks);auto writer=std::make_unique<nanots_writer>(path);auto ctx=std::make_unique<write_context>(writer->create_write_context("series-0","benchmark"));uint64_t rng=1;for(uint64_t i=0;i<base;i++){Point p{int64_t(i),value_for(i,false,rng)};writer->write(*ctx,(uint8_t*)&p,16,0,p.ts);}std::atomic<bool>go=false,stop=false;std::atomic<uint64_t>writes=0,queries=0;std::mutex lm;std::vector<uint64_t>lat;std::vector<std::thread>rt;for(int r=0;r<readers;r++)rt.emplace_back([&,r]{nanots_iterator it(path,"series-0");uint64_t rs=r+7,hash=0;while(!go.load()){}while(!stop.load()){int64_t st=splitmix(rs)%(base-99);auto a=Clock::now();if(!it.find(st))fail("nano concurrent find");for(int j=0;j<100;j++){hash^=uint64_t(it->timestamp);if(j<99)++it;}auto b=Clock::now();queries++;if((queries.load()&255)==0){std::lock_guard<std::mutex>g(lm);lat.push_back(ns(a,b));}}consumed.fetch_xor(hash, std::memory_order_relaxed);});auto begin=Clock::now();go=true;uint64_t i=base;while(std::chrono::duration<double>(Clock::now()-begin).count()<seconds){Point p{int64_t(i),double(i)};writer->write(*ctx,(uint8_t*)&p,16,0,p.ts);i++;writes++;}ctx.reset();writer.reset();stop=true;for(auto&t:rt)t.join();double elapsed=std::chrono::duration<double>(Clock::now()-begin).count();return{{elapsed,writes.load(),writes.load(),files_size(path)},{elapsed,queries.load(),queries.load()*100,0,lat,{}}};}

static Concurrent concurrent_sqlite(const std::string&path,int readers,int seconds,uint64_t base){
  build("sqlite",path,base,1,false,false,65536);
  Sqlite db(path,false);db.exec("PRAGMA synchronous=FULL");db.prepare_insert();
  std::atomic<bool>go=false,stop=false;std::atomic<uint64_t>writes=0,queries=0;std::mutex lm;std::vector<uint64_t>lat;std::vector<std::thread>rt;
  for(int r=0;r<readers;r++)rt.emplace_back([&,r]{Sqlite reader_db(path,false);sqlite3_stmt*q=nullptr;sql_ok(sqlite3_prepare_v2(reader_db.db,"SELECT ts,value FROM points WHERE series_id=0 AND ts>=? ORDER BY ts LIMIT 100",-1,&q,nullptr),reader_db.db,"concurrent prepare");uint64_t rng=r+7,hash=0;while(!go.load()){}while(!stop.load()){int64_t st=splitmix(rng)%(base-99);sqlite3_bind_int64(q,1,st);auto a=Clock::now();int n=0;while(sqlite3_step(q)==SQLITE_ROW){hash^=sqlite3_column_int64(q,0);n++;}auto b=Clock::now();if(n!=100)fail("sqlite concurrent short");sqlite3_reset(q);sqlite3_clear_bindings(q);queries++;if((queries.load()&255)==0){std::lock_guard<std::mutex>g(lm);lat.push_back(ns(a,b));}}sqlite3_finalize(q);consumed.fetch_xor(hash, std::memory_order_relaxed);});
  // Give every reader time to prepare before the measured writer begins.
  std::this_thread::sleep_for(std::chrono::milliseconds(100));db.exec("BEGIN IMMEDIATE");auto begin=Clock::now();go=true;uint64_t i=base;
  while(std::chrono::duration<double>(Clock::now()-begin).count()<seconds){db.add(0,i,double(i));i++;writes++;if((i-base)%65536==0){db.exec("COMMIT");db.exec("BEGIN IMMEDIATE");}}
  db.exec("COMMIT");stop=true;for(auto&t:rt)t.join();double elapsed=std::chrono::duration<double>(Clock::now()-begin).count();return{{elapsed,writes.load(),writes.load(),files_size(path)},{elapsed,queries.load(),queries.load()*100,0,lat,{}}};
}

static void print_metrics(const Metrics&m,const std::string&engine,const std::string&workload,int run){std::cout<<std::setprecision(12)<<"{\"engine\":\""<<engine<<"\",\"workload\":\""<<workload<<"\",\"run\":"<<run<<",\"seconds\":"<<m.seconds<<",\"operations\":"<<m.operations<<",\"points\":"<<m.points<<",\"file_bytes\":"<<m.bytes<<",\"p50_ns\":"<<percentile(m.latency,.50)<<",\"p99_ns\":"<<percentile(m.latency,.99)<<",\"sync_p50_ns\":"<<percentile(m.sync_latency,.50)<<",\"sync_p99_ns\":"<<percentile(m.sync_latency,.99)<<",\"checksum\":"<<consumed.load()<<"}"<<std::endl;}
int main(int argc,char**argv){try{if(argc<2)fail("missing command");std::string cmd=argv[1];if(cmd=="append"){if(argc!=11)fail("append engine path count series boundary codec pattern run");std::string e=argv[2],p=argv[3];uint64_t n=std::stoull(argv[4]);int s=std::stoi(argv[5]);uint64_t b=std::stoull(argv[6]);bool c=std::string(argv[7])=="compressed",r=std::string(argv[8])=="random";int run=std::stoi(argv[9]);std::string label=argv[10];auto m=build(e,p,n,s,c,r,b);verify_db(e,p,n,s);print_metrics(m,e,label,run);}
else if(cmd=="query"){if(argc!=11)fail("query engine path dataset queries width codec run label");std::string e=argv[2],p=argv[3];uint64_t ds=std::stoull(argv[4]),q=std::stoull(argv[5]);int w=std::stoi(argv[6]);bool c=std::string(argv[7])=="compressed";int run=std::stoi(argv[8]);std::string label=argv[9];uint64_t seed=std::stoull(argv[10]);build(e,p,ds,1,c,false,65536);verify_db(e,p,ds,1);auto m=query(e,p,q,w,ds,seed);verify_db(e,p,ds,1);m.bytes=files_size(p);print_metrics(m,e,label,run);}
else if(cmd=="concurrent"){if(argc!=8)fail("concurrent engine path readers seconds run label");std::string e=argv[2],p=argv[3];int readers=std::stoi(argv[4]),secs=std::stoi(argv[5]),run=std::stoi(argv[6]);std::string label=argv[7];Concurrent c=e=="chronotail"?concurrent_chrono(p,readers,secs,1000000):e=="nanots"?concurrent_nano(p,readers,secs,1000000):concurrent_sqlite(p,readers,secs,1000000);verify_db(e,p,1000000+c.writer.operations,1);print_metrics(c.writer,e,label+"-writer",run);print_metrics(c.reader,e,label+"-readers",run);}
else fail("unknown command");return 0;}catch(const std::exception&e){std::cerr<<"ERROR: "<<e.what()<<"\n";return 1;}}
