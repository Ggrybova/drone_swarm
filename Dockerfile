# --- build ---
FROM erlang:29-alpine AS build
WORKDIR /app
COPY rebar.config rebar.lock ./
RUN rebar3 get-deps
COPY config config
COPY include include
COPY priv priv
COPY src src
RUN rebar3 as prod release

# --- run ---
FROM erlang:29-alpine
WORKDIR /app
COPY --from=build /app/_build/prod/rel/drone_swarm ./
EXPOSE 8080
CMD ["bin/drone_swarm", "foreground"]
