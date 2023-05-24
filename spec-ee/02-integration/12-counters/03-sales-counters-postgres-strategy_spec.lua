-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local pg_strategy = require "kong.counters.sales.strategies.postgres"
local utils       = require "kong.tools.utils"
local helpers     = require "spec.helpers"

local LICENSE_DATA_TNAME = "license_data"
local license_creation_date = "2019-03-03"

local current_date = tostring(os.date("%Y-%m-%d"))
local current_year = tonumber(os.date("%Y"))
local current_month = tonumber(os.date("%m"))
local license_strategies = {
  "licensed",
  "unlicensed",
}

local function get_license_creation_date(license_strategy)
  if license_strategy == "licensed" then
    return license_creation_date
  end

  return current_date
end

local ffi = require('ffi')
ffi.cdef([[
  int unsetenv(const char* name);
]])

for _, strategy in helpers.each_strategy({"postgres"}) do
  for _, license_strategy in ipairs(license_strategies) do
    describe("Sales counters strategy #" .. strategy .. " for #" .. license_strategy .. " Kong", function()
      local strategy
      local db
      local snapshot


      setup(function()
        if license_strategy == license_strategies.unlicensed then
          ffi.C.unsetenv("KONG_LICENSE_DATA")
          ffi.C.unsetenv("KONG_LICENSE_PATH")
        end

        db = select(2, helpers.get_db_utils(strategy))
        strategy = pg_strategy:new(db)
        db = db.connector
      end)


      before_each(function()
        snapshot = assert:snapshot()

        assert(db:query("truncate table " .. LICENSE_DATA_TNAME))
      end)


      after_each(function()
        snapshot:revert()
      end)


      teardown(function()
        assert(db:query("truncate table " .. LICENSE_DATA_TNAME))
      end)

      describe(":insert_stats()", function()
        it("should flush data to postgres from one node", function()
          local data = {
            request_count = 10,
            license_creation_date = get_license_creation_date(license_strategy),
            node_id = utils.uuid()
          }

          strategy:flush_data(data)

          local res, _ = db:query("select * from " .. LICENSE_DATA_TNAME .. " WHERE node_id = '" .. tostring(data.node_id) .. "'")

          local expected_data = {
            node_id  = data.node_id,
            license_creation_date = get_license_creation_date(license_strategy) .. " 00:00:00",
            req_cnt = 10,
            year = current_year,
            month = current_month,
          }

          assert.same(expected_data.node_id, res[1].node_id)
          assert.same(expected_data.license_creation_date, res[1].license_creation_date)
          assert.same(expected_data.req_cnt, res[1].req_cnt)
          assert.same(expected_data.year, res[1].year)
          assert.same(expected_data.month, res[1].month)
        end)

        it("should flush data to postgres with more than one row from node", function()
          local data = {
            request_count = 10,
            license_creation_date = get_license_creation_date(license_strategy),
            node_id = utils.uuid()
          }

          strategy:flush_data(data)

          local res, _ = db:query("select * from " .. LICENSE_DATA_TNAME .. " WHERE node_id = '" .. tostring(data.node_id) .. "'")

          local expected_data = {
            node_id  = data.node_id,
            license_creation_date = get_license_creation_date(license_strategy) .. " 00:00:00",
            req_cnt = 10,
            year = current_year,
            month = current_month,
          }

          assert.same(expected_data.node_id, res[1].node_id)
          assert.same(expected_data.license_creation_date, res[1].license_creation_date)
          assert.same(expected_data.req_cnt, res[1].req_cnt)
          assert.same(expected_data.year, res[1].year)
          assert.same(expected_data.month, res[1].month)

          local data = {
            request_count = 269,
            license_creation_date = get_license_creation_date(license_strategy),
            node_id = data.node_id
          }

          strategy:flush_data(data)

          res, _ = db:query("select * from " .. LICENSE_DATA_TNAME .. " WHERE node_id = '" .. tostring(data.node_id) .. "'")

          local expected_data = {
            node_id  = data.node_id,
            license_creation_date = get_license_creation_date(license_strategy) .. " 00:00:00",
            req_cnt = 279,
            year = current_year,
            month = current_month,
          }

          assert.same(expected_data.node_id, res[1].node_id)
          assert.same(expected_data.license_creation_date, res[1].license_creation_date)
          assert.same(expected_data.req_cnt, res[1].req_cnt)
          assert.same(expected_data.year, res[1].year)
          assert.same(expected_data.month, res[1].month)
        end)

        it("should flush data to postgres from more than one node", function()
          local data = {
            request_count = 10,
            license_creation_date = get_license_creation_date(license_strategy),
            node_id = utils.uuid()
          }

          strategy:flush_data(data)

          local res, _ = db:query("select * from " .. LICENSE_DATA_TNAME .. " WHERE node_id = '" .. tostring(data.node_id) .. "'")

          local expected_data = {
            node_id  = data.node_id,
            license_creation_date = get_license_creation_date(license_strategy) .. " 00:00:00",
            req_cnt = 10,
            year = current_year,
            month = current_month,
          }

          assert.same(expected_data.node_id, res[1].node_id)
          assert.same(expected_data.license_creation_date, res[1].license_creation_date)
          assert.same(expected_data.req_cnt, res[1].req_cnt)
          assert.same(expected_data.year, res[1].year)
          assert.same(expected_data.month, res[1].month)

          local data = {
            request_count = 58,
            license_creation_date = get_license_creation_date(license_strategy),
            node_id = utils.uuid()
          }

          strategy:flush_data(data)

          res, _ = db:query("select * from " .. LICENSE_DATA_TNAME .. " WHERE node_id = '" .. tostring(data.node_id) .. "'")

          local expected_data = {
            node_id  = data.node_id,
            license_creation_date = get_license_creation_date(license_strategy) .. " 00:00:00",
            req_cnt = 58,
            year = current_year,
            month = current_month,
          }

          assert.same(expected_data.node_id, res[1].node_id)
          assert.same(expected_data.license_creation_date, res[1].license_creation_date)
          assert.same(expected_data.req_cnt, res[1].req_cnt)
          assert.same(expected_data.year, res[1].year)
          assert.same(expected_data.month, res[1].month)
        end)
      end)
    end)
  end
end