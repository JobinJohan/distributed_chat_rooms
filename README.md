# Project description
Ce projet repose sur l’implémentation distribuée de salons de discussion et de clients
– à la fois des bots et des humains – en langage Erlang. Le défi principal est de garantir
un fonctionnement stable du système s’appuyant sur l’exclusion mutuelle sans que
cela n’impacte les utilisateurs. En effet, le nombre de requêtes peut rapidement
devenir important car les clients ont la possibilité de changer de salon de discussion
et d’interagir avec les autres clients en envoyant et en recevant des messages. De ce
fait, il est essentiel que toutes les requêtes soient correctement traitées, et ce, en
gardant un ordre cohérent d’arrivée des messages dans les salles de discussion.

# Architecture
![Architecture](./doc/architecture.png)
